require "test_helper"

class AccountDeletionTest < ActionDispatch::IntegrationTest
  test "deleting the account erases the user, identity, session key, sessions and connection" do
    sign_in_via_lastfm(username: "listener")
    token = session_cookie
    user = User.sole

    delete "/api/account", params: { confirm_name: "LISTENER" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal "https://www.last.fm/settings/applications", response.parsed_body["revokeAccessUrl"]
    assert_nil response.parsed_body["spotifyAppsUrl"], "no Spotify was connected"

    assert_not User.exists?(user.id)
    assert_equal 0, Identity.count
    assert_equal 0, Session.count
    assert_equal 0, LastfmConnection.count
    assert_predicate cookies[Authentication::COOKIE_NAME], :blank?

    cookies[Authentication::COOKIE_NAME] = token
    get "/api/connection"
    assert_equal({ "status" => "signed_out" }, response.parsed_body)
  end

  test "deletion requires typing the display name" do
    sign_in_via_lastfm(username: "listener")

    delete "/api/account", params: { confirm_name: "someone-else" }, headers: same_origin_headers, as: :json
    assert_response :unprocessable_content
    assert_equal "confirmation_mismatch", response.parsed_body["error"]
    assert_equal 1, User.count
  end

  test "deletion only touches the signed-in user's data (multi-account mode)" do
    allow_lastfm_accounts("other", "listener")
    sign_in_via_lastfm(username: "other")
    reset!
    sign_in_via_lastfm(username: "listener")

    delete "/api/account", params: { confirm_name: "listener" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal [ "other" ], Identity.pluck(:uid)
  end

  test "deletion needs a session and a same-origin request" do
    delete "/api/account", params: { confirm_name: "listener" }, headers: same_origin_headers, as: :json
    assert_response :unauthorized

    sign_in_via_lastfm(username: "listener")
    delete "/api/account", params: { confirm_name: "listener" }, headers: { "Origin" => "https://evil.example", "X-Requested-With" => "XMLHttpRequest" }, as: :json
    assert_response :forbidden
    assert_equal 1, User.count
  end

  private

  def same_origin_headers
    { "Origin" => "http://localhost:5173", "X-Requested-With" => "XMLHttpRequest" }
  end

  test "a Spotify-only account is told about Spotify's app settings, not Last.fm's" do
    user = User.create!(display_name: "Dana", reporting_timezone: "America/Los_Angeles")
    ListeningSource.create!(user: user, provider: "spotify", external_account_id: "dana-spotify", display_name: "Dana", state: "connected", connected_at: Time.current)
    _, token = Session.start!(user: user, ip_address: "127.0.0.1", user_agent: "test")
    cookies[Authentication::COOKIE_NAME] = token

    delete "/api/account", params: { confirm_name: "dana" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_equal({ "deleted" => true, "revokeAccessUrl" => nil, "spotifyAppsUrl" => "https://www.spotify.com/account/apps/" }, response.parsed_body)
    assert_not User.exists?(user.id)
  end
end
