require "test_helper"

class AccountPreferencesTest < ActionDispatch::IntegrationTest
  test "the theme is saved on the account and reported with the connection" do
    sign_in_via_lastfm(username: "listener")
    get "/api/connection"
    assert_nil response.parsed_body["theme"]

    patch "/api/account", params: { theme: "moss" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal "moss", User.sole.theme

    get "/api/connection"
    assert_equal "moss", response.parsed_body["theme"]
  end

  test "an unknown theme is refused" do
    sign_in_via_lastfm(username: "listener")
    patch "/api/account", params: { theme: "neon" }, headers: same_origin_headers, as: :json
    assert_response :unprocessable_content
    assert_nil User.sole.theme
  end

  test "saving a theme needs a session" do
    patch "/api/account", params: { theme: "moss" }, headers: same_origin_headers, as: :json
    assert_response :unauthorized
  end
end
