require "test_helper"

# Connecting Spotify through the browser flow (docs/spotify-plan.md §8): start on the app origin,
# begin and callback on the loopback redirect origin, state and nonce checks, errors, the sources
# endpoint, and disconnecting. Spotify is stubbed.
class SpotifyConnectionTest < ActionDispatch::IntegrationTest
  CALLBACK_ORIGIN = "http://127.0.0.1:3000".freeze

  # A request on the loopback redirect origin. Integration sessions stay on the last host used, so
  # this returns to the app's own host afterwards, as the browser does when it goes back to Settings.
  def on_callback_origin(path, **params)
    get "#{CALLBACK_ORIGIN}#{path}", params: params
    host! "localhost:5173"
    response
  end

  def start!
    get "/api/auth/spotify"
    assert_response :redirect
    location = URI(response.location)
    assert_equal [ "127.0.0.1", 3000, "/api/auth/spotify/begin" ], [ location.host, location.port, location.path ], response.location
    Rack::Utils.parse_query(location.query).fetch("state")
  end

  def begin!(state)
    on_callback_origin("/api/auth/spotify/begin", state: state)
    assert_response :redirect
    URI(response.location)
  end

  def connect!
    sign_in_via_lastfm(username: "listener")
    stub_spotify_tokens
    stub_spotify_me
    state = start!
    begin!(state)
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    response
  end

  test "the full flow connects the signed-in user's account and returns to Settings without exposing tokens" do
    sign_in_via_lastfm(username: "listener")
    state = start!
    spotify = begin!(state)
    query = Rack::Utils.parse_query(spotify.query)
    assert_equal "https://accounts.spotify.com/authorize", "#{spotify.scheme}://#{spotify.host}#{spotify.path}"
    assert_equal({ "client_id" => "test-spotify-client", "response_type" => "code", "redirect_uri" => "#{CALLBACK_ORIGIN}/api/auth/spotify/callback",
                   "scope" => "user-read-recently-played", "state" => state, "show_dialog" => "true" }, query)

    stub_spotify_tokens
    stub_spotify_me
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    assert_equal "http://localhost:5173/settings?spotify=connected#sources", response.location
    source = ListeningSource.sole
    assert_equal [ User.sole.id, "spotify-user", "connected" ], source.values_at(:user_id, :external_account_id, :state)

    get "/api/listening-sources"
    body = response.parsed_body
    assert_equal({ "id" => "spotify-user", "displayName" => "Listener" }, body.dig("spotify", "account"))
    assert_equal [ "connected", true, false ], [ body.dig("spotify", "state"), body.dig("spotify", "configured"), body.dig("spotify", "ingestionEnabled") ]
    assert_equal({ "role" => "archive", "connected" => true, "username" => "listener" }, body["lastfm"])
    assert_not_includes response.body, "access-1"
    assert_not_includes response.body, "refresh-1"
  end

  test "the callback needs the browser that started it, a valid state, and the signed-in user" do
    sign_in_via_lastfm(username: "listener")
    state = start!
    stub_spotify_tokens
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    assert_equal "http://localhost:5173/settings?spotify_error=state#sources", response.location, "no nonce cookie: another browser"

    begin!(state)
    on_callback_origin("/api/auth/spotify/callback", state: state.reverse, code: "auth-code")
    assert_match(/spotify_error=state/, response.location)
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    assert_match(/spotify_error=state/, response.location, "the nonce cookie is single-use")

    on_callback_origin("/api/auth/spotify/begin", state: "forged")
    assert_match(/spotify_error=state/, response.location)
    assert_not_requested :post, SpotifyStubs::TOKEN_URL
    assert ListeningSource.none?

    reset!
    get "/api/auth/spotify"
    assert_equal "http://localhost:5173/settings?spotify_error=signed_out#sources", response.location
  end

  test "declining at Spotify, or Spotify refusing, returns a short code to Settings" do
    sign_in_via_lastfm(username: "listener")
    state = start!
    begin!(state)
    on_callback_origin("/api/auth/spotify/callback", state: state, error: "access_denied")
    assert_match(/spotify_error=denied/, response.location)

    state = start!
    begin!(state)
    stub_spotify_tokens(status: 503, body: { error: "server_error" })
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code")
    assert_match(/spotify_error=spotify_unavailable/, response.location)
    assert ListeningSource.none?
  end

  test "disconnecting forgets the credentials and keeps the source; reconnecting works" do
    connect!
    post "/api/listening-sources/spotify/disconnect"
    assert_response :forbidden, "same-origin headers required"
    post "/api/listening-sources/spotify/disconnect", headers: same_origin_headers
    assert_response :ok
    assert_equal "disconnected", response.parsed_body.dig("spotify", "state")
    assert_equal [ "disconnected", nil ], ListeningSource.sole.values_at(:state, :credentials)

    stub_spotify_tokens(access: "access-9")
    state = start!
    begin!(state)
    on_callback_origin("/api/auth/spotify/callback", state: state, code: "auth-code-2")
    assert_equal [ 1, "connected", "access-9" ], [ ListeningSource.count, ListeningSource.sole.state, ListeningSource.sole.credentials["access_token"] ]
  end

  test "sources are per user and need a session" do
    get "/api/listening-sources"
    assert_response :unauthorized
    allow_lastfm_accounts("listener", "other")
    connect!
    reset!
    sign_in_via_lastfm(username: "other")
    get "/api/listening-sources"
    assert_equal "not_connected", response.parsed_body.dig("spotify", "state")
    post "/api/listening-sources/spotify/disconnect", headers: same_origin_headers
    assert_response :not_found
    assert_equal "connected", ListeningSource.sole.state
  end
end
