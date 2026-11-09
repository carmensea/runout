require "test_helper"
require "webauthn/fake_client"
require "rake"

# Google sign-in (docs/google-sign-in.md), end to end against a stubbed Google: the real code
# exchange and the real ID-token verification, with tokens signed by a key generated here and
# published at the stubbed keys endpoint. Fictional people and addresses.
class GoogleSignInTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  ORIGIN = "http://localhost:5173".freeze
  CLIENT_ID = "runout-test.apps.googleusercontent.com".freeze
  KEY = OpenSSL::PKey::RSA.generate(2048)
  JWK = JWT::JWK.new(KEY, kid: "test-key")

  setup do
    @flag = Rails.configuration.x.passkeys_enabled
    Rails.configuration.x.passkeys_enabled = "true"
    @env = ENV.to_h.slice("GOOGLE_CLIENT_ID", "GOOGLE_CLIENT_SECRET")
    ENV["GOOGLE_CLIENT_ID"] = CLIENT_ID
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"
    Rails.cache.clear
    stub_request(:get, GoogleSignIn::Config::JWKS_URL).to_return(status: 200, body: { keys: [ JWK.export ] }.to_json)
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:invite_link")
  end

  teardown do
    Rails.configuration.x.passkeys_enabled = @flag
    %w[GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET].each { |k| @env.key?(k) ? ENV[k] = @env[k] : ENV.delete(k) }
  end

  def json = response.parsed_body
  def post_json(path, body = {}) = post(path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json"))

  # An ID token as Google would sign it for this browser's flow; any claim can be bent.
  def id_token(sub:, nonce:, email: "#{sub}@example.com", key: KEY, kid: "test-key", **claims)
    payload = { iss: "https://accounts.google.com", aud: CLIENT_ID, sub: sub, email: email, email_verified: true, nonce: nonce,
                iat: Time.current.to_i, exp: 10.minutes.from_now.to_i }.merge(claims)
    JWT.encode(payload, key, "RS256", kid: kid)
  end

  # Starts the flow and returns what Runout sent to Google: the state and the nonce.
  def start_google(intent: "sign_in", back: nil)
    get "/api/auth/google", params: { intent: intent, return: back }.compact
    return nil unless response.location.to_s.start_with?(GoogleSignIn::Config::AUTHORIZE_URL)

    Rack::Utils.parse_query(URI(response.location).query)
  end

  # The whole round trip as `sub`: start, Google's answer, the callback. `token:` builds the ID
  # token from the flow's nonce (default: a valid one).
  def google!(sub, intent: "sign_in", back: nil, token: nil)
    sent = start_google(intent: intent, back: back) or return response
    signed = token ? token.call(sent["nonce"]) : id_token(sub: sub, nonce: sent["nonce"])
    stub_request(:post, GoogleSignIn::Config::TOKEN_URL).to_return(status: 200, body: { id_token: signed }.to_json)
    get "/api/auth/google/callback", params: { state: sent["state"], code: "code-#{sub}" }
    response
  end

  # Rake runs a task once per process unless re-armed: before, in case another test left it spent,
  # and after, so this one leaves it ready for the tests that follow.
  def invite!(name = "Dana")
    task = Rake::Task["auth:invite_link"]
    task.reenable
    out, = capture_io { task.invoke(name, "America/Los_Angeles") }
    out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}] or flunk("no link in #{out.inspect}")
  ensure
    task&.reenable
  end

  def enrol_passkey!(client = WebAuthn::FakeClient.new(ORIGIN))
    post_json "/api/passkeys/options"
    post_json "/api/passkeys", { credential: client.create(challenge: json["challenge"], user_verified: true), nickname: "Laptop" }
    assert_response :created
    client
  end

  def sign_out! = delete("/api/session", headers: same_origin_headers)

  test "the flow asks Google for identity only, and binds the browser with a state and a nonce" do
    sent = start_google
    assert_equal CLIENT_ID, sent["client_id"]
    assert_equal "openid email", sent["scope"]
    assert_equal "code", sent["response_type"]
    assert_equal "#{ORIGIN}/api/auth/google/callback", sent["redirect_uri"]
    assert_operator sent["state"].length, :>=, 43
    assert_operator sent["nonce"].length, :>=, 43
    refute_equal sent["state"], sent["nonce"]
  end

  test "an invited person chooses Google: no passkey, no recovery codes, and signs in again later" do
    link = invite!
    get link
    assert_redirected_to "/welcome"
    get "/api/session"
    assert_equal({ "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false, "google" => false, "googleEmail" => nil }, json["methods"])
    assert_equal({ "google" => true }, json["providers"])

    google!("g-dana", intent: "link", back: "welcome")
    assert_redirected_to "#{ORIGIN}/welcome?google=linked"
    dana = User.sole
    identity = dana.google_identity
    assert_equal [ "google", "g-dana", "g-dana@example.com" ], [ identity.provider, identity.uid, identity.username ]
    assert_nil identity.credentials
    get "/api/session"
    assert_equal({ "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false, "google" => true, "googleEmail" => "g-dana@example.com" }, json["methods"])
    assert_equal 0, RecoveryCode.count, "nobody is made to save codes to use Google"

    # Enrolled through Google: the invitation is closed, as it is after a passkey.
    sign_out!
    get link
    assert_redirected_to "/overview?auth_error=link_invalid"

    # Coming back: Google signs the same account in. One account, one identity.
    google!("g-dana")
    assert_redirected_to "#{ORIGIN}/overview"
    get "/api/connection"
    assert_equal "Dana", json["displayName"]
    assert_equal [ 1, 1 ], [ User.count, Identity.count ]
  end

  test "a Google account nobody linked signs nobody in and creates nothing" do
    google!("g-stranger")
    assert_redirected_to "#{ORIGIN}/overview?google_error=no_account"
    assert_nil session_cookie.presence
    assert_equal [ 0, 0, 0 ], [ User.count, Identity.count, Session.count ]
    get "/api/connection"
    assert_equal "signed_out", json["status"]
  end

  test "an address is never an account: the same email under another subject matches nothing" do
    get invite!
    google!("g-dana", intent: "link", back: "welcome")
    sign_out!
    google!("g-impostor", token: ->(nonce) { id_token(sub: "g-impostor", nonce: nonce, email: "g-dana@example.com") })
    assert_redirected_to "#{ORIGIN}/overview?google_error=no_account"
    assert_equal 1, Identity.count
  end

  test "an existing passkey account links Google and keeps everything; either method signs in" do
    get invite!
    client = enrol_passkey!
    dana = User.sole
    # Their listening and a memory about it, which linking must not touch.
    played = variant(track: "Harbour Lights", artist: "The Lanterns", album: "Night Ferry")
    Catalogue::Matcher.new.match!(played)
    scrobble(dana, at: Time.utc(2014, 3, 15, 20), variant: played)
    Memory.create!(user: dana, track: played.reload.track, body: "Kept.")
    source = ListeningSource.create!(user: dana, provider: "spotify", external_account_id: "dana-spotify", display_name: "Dana", state: "connected", connected_at: Time.current)
    before = { passkeys: WebauthnCredential.count, codes: RecoveryCode.count, memories: Memory.pluck(:body), plays: dana.scrobbles.count,
               source: source.state, name: dana.display_name }

    google!("g-dana", intent: "link", back: "settings")
    assert_redirected_to "#{ORIGIN}/settings?google=linked#sign-in"
    assert_equal 1, User.count, "no second account"
    assert_equal before, { passkeys: WebauthnCredential.count, codes: RecoveryCode.count, memories: Memory.pluck(:body), plays: dana.scrobbles.count,
                           source: source.reload.state, name: dana.reload.display_name }
    get "/api/session"
    assert_equal [ 1, true ], json["methods"].values_at("passkeys", "google")

    sign_out!
    google!("g-dana")
    assert_redirected_to "#{ORIGIN}/overview"
    sign_out!
    post_json "/api/auth/passkey/options"
    post_json "/api/auth/passkey", { credential: client.get(challenge: json["challenge"], user_verified: true) }
    assert_response :ok
    assert_equal "Dana", json.dig("user", "displayName")

    # With both, either can go: the passkey may be removed because Google remains…
    RecoveryCode.where(user: dana).delete_all
    delete "/api/passkeys/#{WebauthnCredential.sole.id}", headers: same_origin_headers
    assert_response :no_content
    # …and then Google is the last way in and stays.
    delete "/api/auth/google", headers: same_origin_headers
    assert_response :conflict
    assert_equal "last_method", json["error"]
    assert dana.reload.google_identity
  end

  test "linking and unlinking need a fresh session; unlinking ends the account's other sessions" do
    get invite!
    enrol_passkey!
    dana = User.sole
    _, other_browser = Session.start!(user: dana, ip_address: "203.0.113.9", user_agent: "another browser")

    travel 11.minutes do
      get "/api/auth/google", params: { intent: "link", return: "settings" }
      assert_redirected_to "#{ORIGIN}/settings?google_error=confirm_first#sign-in"
      assert_nil dana.reload.google_identity
    end

    google!("g-dana", intent: "link", back: "settings")
    assert dana.reload.google_identity

    travel 11.minutes do
      delete "/api/auth/google", headers: same_origin_headers
      assert_response :forbidden
      assert_equal "confirm_first", json["error"]
      assert dana.reload.google_identity
      # Signing in again (here with Google itself) is the fresh proof.
      google!("g-dana", back: "settings")
      assert_redirected_to "#{ORIGIN}/settings#sign-in"
      delete "/api/auth/google", headers: same_origin_headers
      assert_response :no_content
    end
    assert_nil dana.reload.google_identity
    assert_nil Session.find_by_token(other_browser), "a way in was withdrawn: other browsers are signed out"
    assert_equal 1, dana.sessions.count
    get "/api/session"
    assert_equal true, json["signedIn"], "this browser stays"
  end

  test "a Google account linked to someone else is refused, and an account's own Google is never overwritten" do
    get invite!("Dana")
    google!("g-dana", intent: "link", back: "welcome")
    sign_out!
    get invite!("Robin")
    robin = User.find_by!(display_name: "Robin")

    google!("g-dana", intent: "link", back: "welcome")
    assert_redirected_to "#{ORIGIN}/welcome?google_error=unavailable"
    assert_nil robin.reload.google_identity
    assert_equal "Dana", Identity.find_by!(uid: "g-dana").user.display_name, "nothing moved"

    google!("g-robin", intent: "link", back: "welcome")
    assert_equal "g-robin", robin.reload.google_identity.uid
    google!("g-robin-second", intent: "link", back: "settings")
    assert_redirected_to "#{ORIGIN}/settings?google_error=already_linked#sign-in"
    assert_equal "g-robin", robin.reload.google_identity.uid
    assert_equal [ 2, 2 ], [ User.count, Identity.count ]

    # Each Google account opens its own Runout account and nobody else's.
    sign_out!
    google!("g-dana")
    get "/api/connection"
    assert_equal "Dana", json["displayName"]
  end

  test "a wrong, missing, replayed or expired state completes nothing" do
    get invite!
    sent = start_google(intent: "link", back: "welcome")
    stub_request(:post, GoogleSignIn::Config::TOKEN_URL).to_return(status: 200, body: { id_token: id_token(sub: "g-dana", nonce: sent["nonce"]) }.to_json)

    get "/api/auth/google/callback", params: { state: "#{sent['state']}x", code: "c" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=state"
    # The cookie was spent by that attempt: the right state no longer completes either.
    get "/api/auth/google/callback", params: { state: sent["state"], code: "c" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=state"

    sent = start_google(intent: "link", back: "welcome")
    travel 11.minutes do
      get "/api/auth/google/callback", params: { state: sent["state"], code: "c" }
      assert_redirected_to "#{ORIGIN}/overview?google_error=state"
    end

    # No flow started in this browser at all (login CSRF): nothing happens.
    get "/api/auth/google/callback", params: { state: "anything", code: "c" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=state"
    assert_equal 0, Identity.count
    assert_not_requested :post, GoogleSignIn::Config::TOKEN_URL
  end

  test "a link started by one account cannot be completed in another account's session" do
    get invite!("Dana")
    sent = start_google(intent: "link", back: "welcome")
    stub_request(:post, GoogleSignIn::Config::TOKEN_URL).to_return(status: 200, body: { id_token: id_token(sub: "g-x", nonce: sent["nonce"]) }.to_json)
    # The same browser is now signed in as somebody else (the session changed under the flow).
    get invite!("Robin")
    get "/api/auth/google/callback", params: { state: sent["state"], code: "c" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=signed_out"
    assert_equal 0, Identity.count
  end

  test "ID tokens that do not verify are refused" do
    get invite!
    google!("g-dana", intent: "link", back: "welcome")
    sign_out!
    other_key = OpenSSL::PKey::RSA.generate(2048)
    {
      "signed by another key" => ->(n) { id_token(sub: "g-dana", nonce: n, key: other_key) },
      "for another client" => ->(n) { id_token(sub: "g-dana", nonce: n, aud: "someone-else.apps.googleusercontent.com") },
      "from another issuer" => ->(n) { id_token(sub: "g-dana", nonce: n, iss: "https://accounts.example.com") },
      "expired" => ->(n) { id_token(sub: "g-dana", nonce: n, exp: 1.minute.ago.to_i) },
      "another flow's nonce" => ->(_n) { id_token(sub: "g-dana", nonce: "not-this-browser") },
      "unsigned" => ->(n) { JWT.encode({ iss: "https://accounts.google.com", aud: CLIENT_ID, sub: "g-dana", nonce: n, exp: 10.minutes.from_now.to_i }, nil, "none") },
      "not a token" => ->(_n) { "garbage" }
    }.each do |what, token|
      forget_rate_limits! # so every case is judged on its token, not on how many came before
      google!("g-dana", token: token)
      assert_redirected_to "#{ORIGIN}/overview?google_error=failed", what
      assert_nil session_cookie.presence, what
    end
    assert_equal 0, Session.count

    # Google refusing the code, or no answer at all, is the same plain failure.
    forget_rate_limits!
    sent = start_google
    stub_request(:post, GoogleSignIn::Config::TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant" }.to_json)
    get "/api/auth/google/callback", params: { state: sent["state"], code: "bad" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=failed"
    sent = start_google
    get "/api/auth/google/callback", params: { state: sent["state"], error: "access_denied" }
    assert_redirected_to "#{ORIGIN}/overview?google_error=denied"
  end

  test "an operator session can neither start nor finish a Google flow, nor unlink" do
    get invite!
    google!("g-dana", intent: "link", back: "welcome")
    dana = User.sole
    sign_out!
    _, token = Session.start!(user: dana, ip_address: "127.0.0.1", user_agent: "operator", operator: true)
    cookies[Authentication::COOKIE_NAME] = token

    [ [ :get, "/api/auth/google" ], [ :get, "/api/auth/google?intent=link&return=settings" ], [ :get, "/api/auth/google/callback?state=s&code=c" ], [ :delete, "/api/auth/google" ] ].each do |verb, path|
      send(verb, path, headers: same_origin_headers)
      assert_response :forbidden, "#{verb} #{path}"
      assert_equal "operator_session", json["error"]
    end
    assert_equal "g-dana", dana.reload.google_identity.uid
    assert_equal true, Session.sole.operator, "still the restricted session, nothing new opened"
  end

  test "the routes do not exist without the flag or without a configured client" do
    ENV.delete("GOOGLE_CLIENT_SECRET")
    get "/api/auth/google"
    assert_response :not_found
    get "/api/session"
    assert_equal({ "google" => false }, json["providers"])
    ENV["GOOGLE_CLIENT_SECRET"] = "test-secret"
    Rails.configuration.x.passkeys_enabled = "false"
    get "/api/auth/google"
    assert_response :not_found
    get "/api/auth/google/callback"
    assert_response :not_found
  end

  test "Last.fm sign-in still works beside Google, and deleting the account removes the Google identity" do
    sign_in_via_lastfm(username: "listener")
    owner = User.sole
    google!("g-owner", intent: "link", back: "settings")
    assert_equal %w[google lastfm], owner.identities.pluck(:provider).sort
    get "/api/session"
    assert_equal [ true, true ], json["methods"].values_at("lastfm", "google")

    # Google may go: Last.fm is still a way in.
    delete "/api/auth/google", headers: same_origin_headers
    assert_response :no_content
    google!("g-owner", intent: "link", back: "settings")

    sign_out!
    sign_in_via_lastfm(username: "listener")
    get "/api/connection"
    assert_equal "listener", json["username"]

    delete "/api/account", params: { confirm_name: "listener" }.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
    assert_response :ok
    assert_equal [ 0, 0 ], [ User.count, Identity.count ]
    # The Google account is free again and, with no Runout account, signs nobody in.
    google!("g-owner")
    assert_redirected_to "#{ORIGIN}/overview?google_error=no_account"
  end
end
