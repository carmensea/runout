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

  test "the display name can be changed, trimmed, and is reported everywhere the account is named" do
    sign_in_via_lastfm(username: "listener")
    other = User.create!(display_name: "someone else", reporting_timezone: "UTC")

    patch "/api/account", params: { displayName: "  Dana  " }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal({ "theme" => nil, "displayName" => "Dana" }, response.parsed_body)
    assert_equal "Dana", User.find_by!(id: User.where.not(id: other.id).sole.id).display_name
    assert_equal "someone else", other.reload.display_name

    get "/api/connection"
    assert_equal "Dana", response.parsed_body["displayName"]
    assert_equal "listener", response.parsed_body["username"], "the Last.fm username is not the display name"
    # Deletion confirms against the new name.
    delete "/api/account", params: { confirm_name: "listener" }, headers: same_origin_headers, as: :json
    assert_response :unprocessable_content
  end

  test "a blank, too long or absent name is refused and nothing changes" do
    sign_in_via_lastfm(username: "listener")
    [ { displayName: "   " }, { displayName: "x" * 81 }, {} ].each do |body|
      patch "/api/account", params: body, headers: same_origin_headers, as: :json
      assert_response :unprocessable_content, body.inspect
    end
    assert_equal "listener", User.sole.display_name
  end

  test "saving a theme needs a session" do
    patch "/api/account", params: { theme: "moss" }, headers: same_origin_headers, as: :json
    assert_response :unauthorized
  end
end
