require "test_helper"
require "webauthn/fake_client"
require "rake"

# The invited person's whole journey (docs/multi-user-plan.md §3, §5, PR 4), over HTTP as the browser
# would do it, beside the owner's account: invitation, passkey enrolment, recovery codes, Spotify
# connection, the first recorded play, returning sign-ins with the passkey and with a recovery code,
# and deleting the account without touching the owner's. WebAuthn and Spotify are fakes.
class PilotJourneyTest < ActionDispatch::IntegrationTest
  include HistoryHelpers
  include ActiveJob::TestHelper

  ORIGIN = "http://localhost:5173".freeze
  CALLBACK_ORIGIN = "http://127.0.0.1:3000".freeze
  RECENT = "#{SpotifyStubs::API}/me/player/recently-played".freeze

  setup do
    @passkeys_flag = Rails.configuration.x.passkeys_enabled
    @ingestion_flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.passkeys_enabled = "true"
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:invite_link")
  end

  teardown do
    Rails.configuration.x.passkeys_enabled = @passkeys_flag
    Rails.configuration.x.spotify_ingestion_enabled = @ingestion_flag
  end

  def json = response.parsed_body

  def post_json(path, body = {})
    post path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
  end

  def on_callback_origin(path, **params)
    get "#{CALLBACK_ORIGIN}#{path}", params: params
    host! "localhost:5173"
    response
  end

  def owner_counts(owner)
    [ Scrobble, ListeningSource, ListeningObservation, Session, Identity, LastfmConnection, LovedTrack ].to_h { |m| [ m.name, m.where(user_id: owner.id).count ] }
  end

  test "invitation → passkey → recovery codes → Spotify → first play → returning sign-ins → deletion, beside the owner" do
    # The owner: Last.fm archive, a Spotify source, signed in in their own browser.
    sign_in_via_lastfm(username: "listener")
    owner = User.sole
    owner_token = session_cookie
    scrobble(owner, at: Time.utc(2014, 3, 15, 20), variant: variant(track: "Owner Song", artist: "Band"))
    ListeningSource.create!(user: owner, provider: "spotify", external_account_id: "owner-spotify", display_name: "Owner", state: "connected",
                            connected_at: 1.day.ago, credentials: { "access_token" => "access-owner", "refresh_token" => "r", "expires_at" => 1.year.from_now.to_i })
    before = owner_counts(owner)

    # 1. Invitation, in another browser.
    task = Rake::Task["auth:invite_link"]
    out, = capture_io { task.invoke("Dana", "America/Los_Angeles") }
    task.reenable
    link = out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}] or flunk(out)
    cookies.delete(Authentication::COOKIE_NAME)
    get link
    assert_redirected_to "/welcome"
    dana = User.find_by!(display_name: "Dana")
    assert_equal "America/Los_Angeles", dana.reporting_timezone
    get "/api/session"
    assert_equal({ "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false }, json["methods"])
    get "/api/overview"
    assert_response :conflict, "empty, and never the owner's"

    # 2. Passkey enrolment; the first passkey brings the recovery codes, shown once.
    phone = WebAuthn::FakeClient.new(ORIGIN)
    post_json "/api/passkeys/options"
    post_json "/api/passkeys", { credential: phone.create(challenge: json["challenge"], user_verified: true), nickname: "Phone" }
    assert_response :created
    codes = json["recoveryCodes"]
    assert_equal 10, codes.size
    get "/api/session"
    assert_equal({ "passkeys" => 1, "recoveryCodes" => 10, "lastfm" => false }, json["methods"])
    get link
    assert_redirected_to "/overview?auth_error=link_invalid", "the invitation is dead once the passkey exists"

    # 3. Connect Spotify through the real OAuth flow, bound to Dana by the signed state.
    stub_spotify_tokens(access: "access-dana", refresh: "refresh-dana")
    stub_spotify_me(id: "dana-spotify", name: "Dana")
    get "/api/auth/spotify"
    state = Rack::Utils.parse_query(URI(response.location).query).fetch("state")
    on_callback_origin("/api/auth/spotify/begin", state: state)
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    assert_includes response.location, "spotify=connected"
    source = ListeningSource.find_by!(external_account_id: "dana-spotify")
    assert_equal dana.id, source.user_id
    assert_equal 1, ListeningSource.where(user: owner).count, "the owner's source is untouched"
    get "/api/listening-sources"
    assert_equal "connected", json.dig("spotify", "state")

    # 4. The first poll records the first play on Dana's account only.
    stub_request(:get, RECENT).with(query: { "limit" => "50" }, headers: { "Authorization" => "Bearer access-dana" })
                              .to_return(status: 200, body: { items: [ spotify_item(5.minutes.ago, track: "First Play", artist: "New Band") ], next: nil, cursors: nil }.to_json,
                                         headers: { "Content-Type" => "application/json" })
    perform_enqueued_jobs { SpotifyPollSourceJob.perform_later(source.id) }
    assert_equal 1, Scrobble.where(user: dana).count
    assert_equal "spotify", Scrobble.find_by!(user: dana).source
    get "/api/overview", params: { period: "all" }
    assert_response :ok
    get "/api/plays", params: { period: "all" }
    assert_equal [ "First Play" ], json["plays"].map { |p| p.dig("track", "name") }
    get "/api/search", params: { q: "Owner" }
    assert_equal [], json["tracks"], "search never reaches the owner's plays"

    # 5. Returning: sign out, sign in with the passkey, then with a recovery code.
    delete "/api/session", headers: same_origin_headers
    get "/api/overview"
    assert_response :unauthorized
    post_json "/api/auth/passkey/options"
    post_json "/api/auth/passkey", { credential: phone.get(challenge: json["challenge"], user_verified: true) }
    assert_response :ok
    assert_equal "Dana", json.dig("user", "displayName")
    get "/api/plays", params: { period: "all" }
    assert_equal 1, json["total"]
    delete "/api/session", headers: same_origin_headers
    post_json "/api/auth/recovery", { code: codes.first }
    assert_response :ok
    get "/api/session"
    assert_equal 9, json.dig("methods", "recoveryCodes")
    post_json "/api/auth/recovery", { code: codes.first }
    assert_response :unauthorized, "a code works once"

    # 6. Deletion leaves the owner exactly as they were.
    delete "/api/account", params: { confirm_name: "Dana" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_not User.exists?(dana.id)
    [ Scrobble, ListeningSource, ListeningObservation, ListeningPoll, WebauthnCredential, RecoveryCode, Session, SignInLink ].each do |m|
      assert_equal 0, m.where(user_id: dana.id).count, m.name
    end
    assert_equal before, owner_counts(owner)
    cookies[Authentication::COOKIE_NAME] = owner_token
    get "/api/overview"
    assert_response :ok, "the owner's browser is still signed in"
  end
end
