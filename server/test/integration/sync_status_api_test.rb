require "test_helper"

# GET /api/sync: synchronisation health for the signed-in user only (HistoryImport::SyncHealth).
class SyncStatusApiTest < ActionDispatch::IntegrationTest
  test "requires a signed-in user" do
    get "/api/sync"
    assert_response :unauthorized
  end

  test "reports the signed-in user's health, with storage off and nothing imported" do
    sign_in_via_lastfm(username: "listener")
    get "/api/sync"
    assert_response :ok
    body = response.parsed_body
    assert_equal false, body["enabled"]
    assert_equal false, body["importComplete"]
    assert_equal "not_started", body["connectionState"]
    assert_nil body["lastSuccessfulSyncAt"]
    assert_equal({ "disputes" => 0, "suspectedRemovals" => 0, "pendingRemovals" => 0, "reappeared" => 0 }, body["reviews"])
    assert_equal %w[reconcile catch_up sync], body["nextDue"].keys
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "shows only the signed-in user's periods" do
    allow_lastfm_accounts("other", "listener")
    sign_in_via_lastfm(username: "other")
    other = User.sole
    Rails.configuration.x.history_import_enabled = "true"
    ImportWindow.create!(user: other, window_from: Time.utc(2014, 3, 1), window_to: Time.utc(2014, 4, 1), state: "needs_review")
    Rails.configuration.x.history_import_enabled = "false"
    reset!
    sign_in_via_lastfm(username: "listener")
    get "/api/sync"
    assert_equal [], response.parsed_body["problemPeriods"]
    assert_equal({}, response.parsed_body["periods"])
  end
end
