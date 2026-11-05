require "test_helper"

# The archive opens on stored plays, not on the Last.fm connection (docs/milestone-5-plan.md §2.4).
class ArchiveGateTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  test "a connected account with nothing stored gets 409, and 401 once signed out" do
    sign_in_via_lastfm(username: "listener")
    get "/api/overview"
    assert_response :conflict
    assert_equal "not_connected", response.parsed_body["error"]

    delete "/api/session", headers: same_origin_headers
    get "/api/overview"
    assert_response :unauthorized
  end

  test "stored plays open the archive even without a Last.fm connection" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    scrobble(user, at: Time.utc(2014, 3, 15, 20))
    user.lastfm_connection.destroy!

    get "/api/connection"
    assert_equal "none", response.parsed_body["status"]
    assert_equal "listener", response.parsed_body["displayName"]

    get "/api/overview"
    assert_response :ok
    get "/api/loved-tracks"
    assert_response :ok
  end
end
