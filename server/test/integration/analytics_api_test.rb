require "test_helper"

# Milestone 3: GET /api/overview and GET /api/search for the signed-in user. Synthetic data only.
class AnalyticsApiTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  # The keys src/data/types.ts OverviewData declares, plus Milestone 3's `coverage`.
  OVERVIEW_KEYS = %w[period stats activity mostActiveDays mostActiveMonths habits genres top rankHistory onRepeat
                     backInRotation discovery metadata nearestWithData coverage].freeze

  test "both need a signed-in user" do
    get "/api/overview"
    assert_response :unauthorized
    get "/api/search", params: { q: "ab" }
    assert_response :unauthorized
  end

  test "the overview of the signed-in user's own plays, in the shape the frontend expects" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    scrobble(user, at: Time.utc(2014, 3, 1, 12), variant: variant(track: "Mine", artist: "My Band"))
    other = history_user("other")
    scrobble(other, at: Time.utc(2014, 3, 1, 12), variant: variant(track: "Theirs", artist: "Their Band"))

    get "/api/overview", params: { period: "year:2014" }
    assert_response :ok
    body = response.parsed_body
    assert_equal OVERVIEW_KEYS.sort, body.keys.sort
    assert_equal "year:2014", body["period"]
    assert_equal 1, body.dig("stats", "scrobbles")
    assert_equal [ "My Band" ], body.dig("top", "artists").map { |a| a["name"] }
    assert_equal %w[scrobbles firstScrobbleDate uniqueArtists artistsPlayedOverTen uniqueTracks tracksPlayedOnce uniqueAlbums albumsWithoutArtwork].sort,
                 body["stats"].keys.sort
    assert_nil body["genres"]
    assert_equal "no-store", response.headers["Cache-Control"]

    get "/api/overview", params: { period: "month:2014-13" }
    assert_response :bad_request
  end

  test "search finds only the signed-in user's listening" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    scrobble(user, at: Time.utc(2014, 3, 1), variant: variant(track: "Mine", artist: "Shared Name Band"))
    scrobble(history_user("other"), at: Time.utc(2014, 3, 1), variant: variant(track: "Theirs", artist: "Shared Secret Band"))
    get "/api/search", params: { q: "band" }
    assert_response :ok
    assert_equal [ "Shared Name Band" ], response.parsed_body["artists"].map { |a| a["name"] }
  end
end
