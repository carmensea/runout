require "test_helper"
require "webauthn/fake_client"
require "rake"

# Runout's own sign-in behind RUNOUT_PASSKEYS_ENABLED (docs/milestone-5-plan.md §2): enrolment by a
# signed-in person only, passkey sign-in with a fake authenticator, recovery codes, the operator
# link, other sessions, and 404 for all of it while the flag is off.
class PasskeysTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://localhost:5173".freeze

  setup do
    @flag = Rails.configuration.x.passkeys_enabled
    Rails.configuration.x.passkeys_enabled = "true"
    @client = WebAuthn::FakeClient.new(ORIGIN)
  end

  teardown { Rails.configuration.x.passkeys_enabled = @flag }

  def json = response.parsed_body

  def post_json(path, body = {})
    post path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
  end

  def enrol!(nickname: "Laptop", client: @client)
    post_json "/api/passkeys/options"
    assert_response :ok
    assert_equal "required", json.dig("authenticatorSelection", "residentKey")
    assert_equal "localhost", json.dig("rp", "id")
    credential = client.create(challenge: json["challenge"], user_verified: true)
    post_json "/api/passkeys", { credential: credential, nickname: nickname }
    assert_response :created
    json
  end

  def passkey_sign_in!(client: @client, sign_count: nil, user_handle: nil)
    post_json "/api/auth/passkey/options"
    assert_response :ok
    assertion = client.get(challenge: json["challenge"], user_verified: true, sign_count: sign_count, user_handle: user_handle)
    post_json "/api/auth/passkey", { credential: assertion }
    response
  end

  test "every route answers 404 while the flag is off" do
    sign_in_via_lastfm(username: "listener")
    Rails.configuration.x.passkeys_enabled = "false"
    [ [ :get, "/api/session" ], [ :get, "/api/passkeys" ], [ :post, "/api/passkeys/options" ], [ :post, "/api/passkeys" ],
      [ :delete, "/api/passkeys/1" ], [ :post, "/api/recovery-codes" ], [ :post, "/api/auth/passkey/options" ],
      [ :post, "/api/auth/passkey" ], [ :post, "/api/auth/recovery" ], [ :get, "/api/auth/link/abc" ],
      [ :get, "/api/sessions" ], [ :delete, "/api/sessions/1" ] ].each do |method, path|
      public_send(method, path, headers: same_origin_headers)
      assert_response :not_found, "#{method.upcase} #{path}"
    end
    delete "/api/session", headers: same_origin_headers
    assert_response :no_content, "sign-out is not behind the flag"
  end

  test "GET /api/session describes the signed-in person and their sign-in methods" do
    get "/api/session"
    assert_equal({ "signedIn" => false }, json)

    sign_in_via_lastfm(username: "listener")
    get "/api/session"
    assert_equal({ "signedIn" => true, "user" => { "displayName" => "listener", "timezone" => "Europe/London" },
                   "methods" => { "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => true } }, json)
  end

  test "enrolling needs a session, a fresh challenge and user verification" do
    post_json "/api/passkeys/options"
    assert_response :unauthorized
    post_json "/api/passkeys", { credential: {} }
    assert_response :unauthorized

    sign_in_via_lastfm(username: "listener")
    post_json "/api/passkeys", { credential: @client.create(user_verified: true) }
    assert_equal [ 422, "challenge_expired" ], [ response.status, json["error"] ]

    post_json "/api/passkeys/options"
    credential = @client.create(challenge: json["challenge"], user_verified: false)
    post_json "/api/passkeys", { credential: credential }
    assert_equal [ 422, "passkey_rejected" ], [ response.status, json["error"] ]
    assert_equal 0, WebauthnCredential.count

    post_json "/api/passkeys/options"
    credential = @client.create(challenge: json["challenge"], user_verified: true)
    post_json "/api/passkeys", { credential: credential }
    assert_response :created
    post_json "/api/passkeys", { credential: credential }
    assert_equal "challenge_expired", json["error"], "a challenge is single use"
  end

  test "enrolling never replaces usable recovery codes: none after removal and re-enrolment, a new set only when all are used" do
    sign_in_via_lastfm(username: "listener")
    codes = enrol!(nickname: "Laptop")["recoveryCodes"]
    digests = RecoveryCode.order(:id).pluck(:code_digest)

    delete "/api/passkeys/#{WebauthnCredential.sole.id}", headers: same_origin_headers
    assert_response :no_content
    assert_nil enrol!(nickname: "Laptop again", client: WebAuthn::FakeClient.new(ORIGIN))["recoveryCodes"], "no active passkey, but the codes are still usable"
    assert_equal digests, RecoveryCode.order(:id).pluck(:code_digest), "the set is untouched"

    delete "/api/session", headers: same_origin_headers
    post_json "/api/auth/recovery", { code: codes.first }
    assert_response :ok
    assert_nil enrol!(nickname: "Phone", client: WebAuthn::FakeClient.new(ORIGIN))["recoveryCodes"], "nine codes left"
    assert_equal 9, RecoveryCode.unused.count

    codes.drop(1).each do |code|
      forget_rate_limits! # ten recovery sign-ins in a row would trip the five-an-hour limit
      delete "/api/session", headers: same_origin_headers
      post_json "/api/auth/recovery", { code: code }
      assert_response :ok
    end
    assert_equal 0, RecoveryCode.unused.count
    fresh = enrol!(nickname: "Tablet", client: WebAuthn::FakeClient.new(ORIGIN))["recoveryCodes"]
    assert_equal 10, fresh&.size, "all codes used: a new set, shown once"
    assert_empty fresh & codes
    assert_equal 10, RecoveryCode.unused.count

    post_json "/api/recovery-codes"
    assert_response :created
    assert_equal 10, json["recoveryCodes"].size
    assert_empty json["recoveryCodes"] & fresh, "regenerating on purpose still replaces the set"
  end

  test "the first passkey comes with recovery codes, once; later ones do not" do
    sign_in_via_lastfm(username: "listener")
    first = enrol!(nickname: "Laptop")
    assert_equal "Laptop", first.dig("passkey", "nickname")
    assert_equal 10, first["recoveryCodes"].size
    assert first["recoveryCodes"].all? { |c| c.match?(/\A[a-z2-9]{5}-[a-z2-9]{5}\z/) }, first["recoveryCodes"].inspect
    assert_equal 10, RecoveryCode.unused.count
    assert_empty RecoveryCode.pluck(:code_digest) & first["recoveryCodes"], "codes are stored as digests"

    second = enrol!(nickname: "Phone", client: WebAuthn::FakeClient.new(ORIGIN))
    assert_nil second["recoveryCodes"]
    get "/api/passkeys"
    assert_equal %w[Laptop Phone], json["passkeys"].map { |p| p["nickname"] }
    assert_equal [ 2, 10, true ], User.sole.then { |u| [ u.webauthn_credentials.count, u.recovery_codes.count, u.webauthn_handle.present? ] }
  end

  test "a passkey signs in without a username, with a rotating sign count" do
    sign_in_via_lastfm(username: "listener")
    enrol!
    user = User.sole
    delete "/api/session", headers: same_origin_headers
    get "/api/session"
    assert_equal false, json["signedIn"]

    passkey_sign_in!(sign_count: 5)
    assert_response :ok
    assert_equal [ true, 1 ], [ json["signedIn"], json.dig("methods", "passkeys") ]
    assert_predicate session_cookie, :present?
    assert_equal 1, Session.count, "a new session row; sign-out had removed the Last.fm one"
    assert_equal 5, WebauthnCredential.sole.sign_count
    assert_not_nil WebauthnCredential.sole.last_used_at

    get "/api/connection"
    assert_equal "connected", json["status"], "the Last.fm connection is still there"
    assert_equal user.id, Session.last.user_id
  end

  test "sign-in refuses a reused challenge, a stale sign count, an unknown credential and a revoked one" do
    sign_in_via_lastfm(username: "listener")
    enrol!
    delete "/api/session", headers: same_origin_headers

    post_json "/api/auth/passkey", { credential: @client.get(user_verified: true) }
    assert_equal [ 401, "challenge_expired" ], [ response.status, json["error"] ]

    passkey_sign_in!(sign_count: 10)
    assert_response :ok
    delete "/api/session", headers: same_origin_headers
    passkey_sign_in!(sign_count: 3)
    assert_equal [ 401, "passkey_rejected" ], [ response.status, json["error"] ], "sign count went backwards"
    assert_equal 10, WebauthnCredential.sole.sign_count

    passkey_sign_in!(sign_count: 11, user_handle: "someone else")
    assert_equal [ 401, "passkey_rejected" ], [ response.status, json["error"] ], "handle of another account"

    forget_rate_limits! # a dozen sign-in attempts in a row would trip the ten-a-minute limit
    WebauthnCredential.update_all(revoked_at: Time.current)
    passkey_sign_in!(sign_count: 12)
    assert_equal [ 401, "passkey_rejected" ], [ response.status, json["error"] ], "revoked"

    WebauthnCredential.delete_all
    passkey_sign_in!(sign_count: 13)
    assert_equal [ 401, "passkey_rejected" ], [ response.status, json["error"] ], "unknown credential"
    assert_equal 0, Session.count
  end

  test "sign-in requests are same-origin like every write" do
    post "/api/auth/passkey/options"
    assert_response :forbidden
    post "/api/auth/recovery", params: { code: "x" }, headers: { "Origin" => "https://evil.example", "X-Requested-With" => "XMLHttpRequest" }
    assert_response :forbidden
  end

  test "a recovery code signs in once and the response shows no passkey to insist on a new one" do
    sign_in_via_lastfm(username: "listener")
    codes = enrol!["recoveryCodes"]
    delete "/api/passkeys/#{WebauthnCredential.sole.id}", headers: same_origin_headers
    assert_response :no_content, "the last passkey may go because recovery codes exist"
    delete "/api/session", headers: same_origin_headers

    post_json "/api/auth/recovery", { code: "nope" }
    assert_equal [ 401, "code_rejected" ], [ response.status, json["error"] ]

    post_json "/api/auth/recovery", { code: codes.first.upcase.tr("-", " ") }
    assert_response :ok
    assert_equal({ "passkeys" => 0, "recoveryCodes" => 9, "lastfm" => true }, json["methods"])
    assert_predicate session_cookie, :present?

    delete "/api/session", headers: same_origin_headers
    post_json "/api/auth/recovery", { code: codes.first }
    assert_equal 401, response.status, "single use"

    post_json "/api/auth/recovery", { code: codes.last }
    assert_response :ok
    post_json "/api/recovery-codes"
    assert_response :created
    fresh = json["recoveryCodes"]
    assert_equal 10, fresh.size
    assert_empty fresh & codes
    assert_equal 10, RecoveryCode.unused.count
    delete "/api/session", headers: same_origin_headers
    post_json "/api/auth/recovery", { code: codes[1] }
    assert_equal 401, response.status, "regenerating retires the old set"
  end

  test "the last passkey cannot be removed without recovery codes" do
    sign_in_via_lastfm(username: "listener")
    enrol!
    RecoveryCode.delete_all
    delete "/api/passkeys/#{WebauthnCredential.sole.id}", headers: same_origin_headers
    assert_equal [ 409, "last_passkey" ], [ response.status, json["error"] ]
    assert_nil WebauthnCredential.sole.revoked_at

    delete "/api/passkeys/999", headers: same_origin_headers
    assert_response :not_found
  end

  test "the operator link signs in once within 15 minutes and refuses afterwards" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    delete "/api/session", headers: same_origin_headers

    token = SignInLink.issue!(user)
    get "/api/auth/link/#{token}x"
    assert_redirected_to "/overview?auth_error=link_invalid"
    get "/api/auth/link/#{token}"
    assert_redirected_to "/overview"
    assert_predicate session_cookie, :present?
    get "/api/session"
    assert_equal true, json["signedIn"]

    delete "/api/session", headers: same_origin_headers
    get "/api/auth/link/#{token}"
    assert_redirected_to "/overview?auth_error=link_invalid"

    late = SignInLink.issue!(user)
    travel 16.minutes do
      get "/api/auth/link/#{late}"
      assert_redirected_to "/overview?auth_error=link_invalid"
    end
    assert_equal 1, SignInLink.where(used_at: nil).count
  end

  test "the operator task checks the id and the display name and the flag" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:recovery_link")
    task = Rake::Task["auth:recovery_link"]

    out, = capture_io { task.invoke(user.id, "listener") }
    assert_match %r{\Ahttp://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}$}, out
    assert_equal 1, SignInLink.count
    task.reenable

    assert_raises(SystemExit) { capture_io { task.invoke(user.id, "someone else") } }
    task.reenable
    assert_raises(SystemExit) { capture_io { task.invoke(SecureRandom.uuid, "listener") } }
    task.reenable
    Rails.configuration.x.passkeys_enabled = "false"
    assert_raises(SystemExit) { capture_io { task.invoke(user.id, "listener") } }
    task.reenable
    assert_equal 1, SignInLink.count
  end

  test "other sessions are listed and can be revoked, but only the person's own" do
    sign_in_via_lastfm(username: "listener")
    first = session_cookie
    cookies.delete(Authentication::COOKIE_NAME)
    sign_in_via_lastfm(username: "listener")
    get "/api/sessions"
    assert_equal [ true, false ], json["sessions"].map { |s| s["current"] }
    assert_equal %w[id current createdAt lastSeenAt ipAddress userAgent], json["sessions"].first.keys

    other = json["sessions"].find { |s| !s["current"] }
    delete "/api/sessions/#{other["id"]}", headers: same_origin_headers
    assert_response :no_content
    assert_nil Session.find_by_token(first)
    delete "/api/sessions/999", headers: same_origin_headers
    assert_response :not_found

    allow_lastfm_accounts("listener", "other")
    cookies.delete(Authentication::COOKIE_NAME)
    sign_in_via_lastfm(username: "other")
    mine = Session.last
    delete "/api/sessions/#{Session.where.not(id: mine.id).first.id}", headers: same_origin_headers
    assert_response :not_found, "another user's session is invisible"
    assert_equal 2, Session.count
  end

  test "signing in with a passkey does not touch Last.fm identities or history" do
    sign_in_via_lastfm(username: "listener")
    enrol!
    before = [ Identity.pluck(:updated_at), LastfmConnection.pluck(:updated_at), User.sole.updated_at ]
    delete "/api/session", headers: same_origin_headers
    passkey_sign_in!(sign_count: 1)
    assert_response :ok
    assert_equal before, [ Identity.pluck(:updated_at), LastfmConnection.pluck(:updated_at), User.sole.updated_at ]
  end
end
