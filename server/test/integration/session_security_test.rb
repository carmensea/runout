require "test_helper"

class SessionSecurityTest < ActionDispatch::IntegrationTest
  test "signed-out visitors see no connection" do
    get "/api/connection"
    assert_response :ok
    assert_equal({ "status" => "none" }, response.parsed_body)
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "a tampered cookie is treated as signed out and cleared" do
    sign_in_via_lastfm(username: "listener")
    cookies[Authentication::COOKIE_NAME] = "#{session_cookie}x"

    get "/api/connection"
    assert_equal({ "status" => "none" }, response.parsed_body)
    assert_predicate cookies[Authentication::COOKIE_NAME], :blank?
  end

  test "an expired session is treated as signed out" do
    sign_in_via_lastfm(username: "listener")
    Session.update_all(expires_at: 1.minute.ago)

    get "/api/connection"
    assert_equal({ "status" => "none" }, response.parsed_body)
  end

  test "sign-out requires a same-origin request" do
    sign_in_via_lastfm(username: "listener")

    delete "/api/session"
    assert_response :forbidden

    delete "/api/session", headers: { "Origin" => "https://evil.example", "X-Requested-With" => "XMLHttpRequest" }
    assert_response :forbidden

    delete "/api/session", headers: { "Origin" => "http://localhost:5173" }
    assert_response :forbidden

    assert_equal 1, Session.count
  end

  test "sign-out ends this session server-side, clears the cookie, keeps other sessions and the connections" do
    sign_in_via_lastfm(username: "listener")
    other_token = session_cookie
    cookies.delete(Authentication::COOKIE_NAME)
    sign_in_via_lastfm(username: "listener")
    token = session_cookie
    assert_equal 2, Session.count

    delete "/api/session", headers: same_origin_headers
    assert_response :no_content
    assert_nil Session.find_by_token(token)
    assert_predicate cookies[Authentication::COOKIE_NAME], :blank?, "the cookie is cleared"

    cookies[Authentication::COOKIE_NAME] = token
    get "/api/connection"
    assert_equal({ "status" => "none" }, response.parsed_body)
    get "/api/overview"
    assert_response :unauthorized, "protected data is closed to the ended session"

    assert_not_nil Session.find_by_token(other_token), "another browser's session survives"
    assert_equal [ 1, 1 ], [ Identity.where(revoked_at: nil).count, LastfmConnection.count ], "sign-out touches no connection"
  end

  test "sign-out without a session is unauthorized" do
    delete "/api/session", headers: same_origin_headers
    assert_response :unauthorized
  end

  test "each user sees only their own connection (multi-account mode)" do
    allow_lastfm_accounts("alice", "bob")
    sign_in_via_lastfm(username: "alice")
    alice_token = session_cookie
    WebMock.reset!
    cookies.delete(Authentication::COOKIE_NAME)
    sign_in_via_lastfm(username: "bob", tz: "America/New_York")
    bob_token = session_cookie

    cookies[Authentication::COOKIE_NAME] = alice_token
    get "/api/connection"
    assert_equal "alice", response.parsed_body["username"]

    cookies[Authentication::COOKIE_NAME] = bob_token
    get "/api/connection"
    assert_equal({ "status" => "connected", "username" => "bob", "timezone" => "America/New_York", "theme" => nil }, response.parsed_body)
  end

  test "a revoked Last.fm identity reads as not connected" do
    sign_in_via_lastfm(username: "listener")
    Identity.update_all(revoked_at: Time.current)

    get "/api/connection"
    assert_equal({ "status" => "none" }, response.parsed_body)
  end
end
