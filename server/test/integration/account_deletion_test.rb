require "test_helper"

class AccountDeletionTest < ActionDispatch::IntegrationTest
  test "deleting the account erases the user, identity, session key, sessions and connection" do
    sign_in_via_lastfm(id: 1001, username: "listener")
    token = session_cookie
    user = User.sole

    delete "/api/account", params: { confirm_username: "LISTENER" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal "https://www.last.fm/settings/applications", response.parsed_body["revokeAccessUrl"]

    assert_not User.exists?(user.id)
    assert_equal 0, Identity.count
    assert_equal 0, Session.count
    assert_equal 0, LastfmConnection.count
    assert_predicate cookies[Authentication::COOKIE_NAME], :blank?

    cookies[Authentication::COOKIE_NAME] = token
    get "/api/connection"
    assert_equal({ "status" => "none" }, response.parsed_body)
  end

  test "deletion requires typing the Last.fm username" do
    sign_in_via_lastfm(id: 1001, username: "listener")

    delete "/api/account", params: { confirm_username: "someone-else" }, headers: same_origin_headers, as: :json
    assert_response :unprocessable_content
    assert_equal "confirmation_mismatch", response.parsed_body["error"]
    assert_equal 1, User.count
  end

  test "deletion only touches the signed-in user's data" do
    sign_in_via_lastfm(id: 2002, username: "other")
    reset!
    sign_in_via_lastfm(id: 1001, username: "listener")

    delete "/api/account", params: { confirm_username: "listener" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal [ "2002" ], Identity.pluck(:uid)
  end

  test "deletion needs a session and a same-origin request" do
    delete "/api/account", params: { confirm_username: "listener" }, headers: same_origin_headers, as: :json
    assert_response :unauthorized

    sign_in_via_lastfm(id: 1001, username: "listener")
    delete "/api/account", params: { confirm_username: "listener" }, headers: { "Origin" => "https://evil.example", "X-Requested-With" => "XMLHttpRequest" }, as: :json
    assert_response :forbidden
    assert_equal 1, User.count
  end

  private

  def same_origin_headers
    { "Origin" => "http://localhost:5173", "X-Requested-With" => "XMLHttpRequest" }
  end
end
