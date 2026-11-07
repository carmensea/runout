require "test_helper"

class LastfmSignInTest < ActionDispatch::IntegrationTest
  test "start redirects to Last.fm with a callback carrying a one-time state" do
    get "/api/auth/lastfm", params: { tz: "Europe/London" }

    assert_response :redirect
    location = URI(response.location)
    assert_equal "www.last.fm", location.host
    query = Rack::Utils.parse_query(location.query)
    assert_equal "test-api-key", query["api_key"]
    callback = URI(query["cb"])
    assert_equal "http://localhost:5173/api/auth/lastfm/callback", "#{callback.scheme}://#{callback.host}:#{callback.port}#{callback.path}"
    assert Rack::Utils.parse_query(callback.query)["state"].present?
    assert_not_includes response.location, "test-shared-secret"
  end

  test "a successful callback creates the account, signs in and returns to the Overview" do
    sign_in_via_lastfm(username: "listener")

    assert_redirected_to "/overview"
    assert session_cookie.present?
    set_cookie = Array(response.headers["Set-Cookie"]).join("\n")
    assert_match(/runout_session=.*httponly/i, set_cookie)
    assert_match(/runout_session=.*samesite=lax/i, set_cookie)

    get "/api/connection"
    assert_equal({ "status" => "connected", "displayName" => "listener", "username" => "listener", "timezone" => "Europe/London", "theme" => nil, "features" => [] }, response.parsed_body)
  end

  test "a callback with the wrong state is rejected and signs nobody in" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener")
    get "/api/auth/lastfm"
    get "/api/auth/lastfm/callback", params: { state: "forged", token: "tok" }

    assert_redirected_to "/overview?auth_error=state"
    assert_equal 0, User.count
    assert_not_requested :get, Lastfm::Client::API_URL.to_s, query: hash_including("method" => "auth.getSession")
  end

  test "a callback without the state cookie is rejected" do
    get "/api/auth/lastfm/callback", params: { state: "anything", token: "tok" }
    assert_redirected_to "/overview?auth_error=state"
  end

  test "the state can be used only once" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener")
    get "/api/auth/lastfm"
    state = Rack::Utils.parse_query(URI(Rack::Utils.parse_query(URI(response.location).query)["cb"]).query)["state"]
    get "/api/auth/lastfm/callback", params: { state: state, token: "tok" }
    assert_redirected_to "/overview"

    get "/api/auth/lastfm/callback", params: { state: state, token: "tok" }
    assert_redirected_to "/overview?auth_error=state"
  end

  test "a rejected or expired token reports that Last.fm did not confirm" do
    stub_lastfm_error("auth.getSession", code: 15, message: "This token has expired")
    get "/api/auth/lastfm"
    state = Rack::Utils.parse_query(URI(Rack::Utils.parse_query(URI(response.location).query)["cb"]).query)["state"]
    get "/api/auth/lastfm/callback", params: { state: state, token: "tok" }

    assert_redirected_to "/overview?auth_error=denied"
    assert_nil session_cookie.presence
  end

  test "Last.fm being unavailable is reported separately" do
    stub_lastfm("auth.getSession", body: "Bad Gateway", status: 502)
    get "/api/auth/lastfm"
    get "/api/auth/lastfm/callback", params: { state: issued_state, token: "tok" }

    assert_redirected_to "/overview?auth_error=lastfm_unavailable"
  end

  test "an account this deployment is not configured for is refused" do
    sign_in_via_lastfm(username: "stranger")
    assert_redirected_to "/overview?auth_error=account_not_allowed"
    assert_equal 0, User.count
    assert_nil session_cookie.presence
  end

  test "a missing registration time stops sign-in" do
    sign_in_via_lastfm(username: "listener", registered: nil)
    assert_redirected_to "/overview?auth_error=identity_unverified"
    assert_equal 0, User.count
  end

  test "a username change needs an explicit relink: no new user, original kept" do
    sign_in_via_lastfm(username: "listener")
    user_id = User.sole.id
    delete "/api/session", headers: same_origin_headers

    allow_lastfm_accounts("renamed")
    WebMock.reset!
    sign_in_via_lastfm(username: "renamed")
    assert_redirected_to "/overview?auth_error=relink_required"
    assert_equal [ user_id ], User.pluck(:id)
    assert_equal [ "listener" ], Identity.pluck(:uid)
    assert_nil session_cookie.presence
  end

  test "a linked username with a different registration time is refused" do
    sign_in_via_lastfm(username: "listener", registered: 1199145600)
    delete "/api/session", headers: same_origin_headers

    WebMock.reset!
    sign_in_via_lastfm(username: "listener", registered: 1500000000)
    assert_redirected_to "/overview?auth_error=identity_changed"
    assert_nil session_cookie.presence
  end

  test "signing in replaces any existing session (no fixation)" do
    sign_in_via_lastfm(username: "listener")
    first_token = session_cookie

    WebMock.reset!
    sign_in_via_lastfm(username: "listener")
    assert_not_equal first_token, session_cookie
    assert_nil Session.find_by_token(first_token)
    assert_equal 1, Session.count
  end

  test "start reports when the server has no Last.fm credentials" do
    with_env("LASTFM_API_KEY" => nil) do
      get "/api/auth/lastfm"
      assert_redirected_to "/overview?auth_error=unavailable"
    end
  end

  test "start reports when no Last.fm account is configured" do
    allow_lastfm_accounts
    get "/api/auth/lastfm"
    assert_redirected_to "/overview?auth_error=unavailable"
  end

  private

  def issued_state
    Rack::Utils.parse_query(URI(Rack::Utils.parse_query(URI(response.location).query)["cb"]).query)["state"]
  end

  def with_env(values)
    old = values.keys.index_with { |k| ENV[k] }
    values.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end
end
