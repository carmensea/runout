require "test_helper"

# Time Machine: GET /api/calendar, /api/plays and /api/on-this-day for the signed-in user.
# Synthetic data only.
class TimeMachineApiTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  test "all three need a signed-in user" do
    get "/api/calendar"
    assert_response :unauthorized
    get "/api/plays", params: { period: "day:2014-03-15" }
    assert_response :unauthorized
    get "/api/on-this-day", params: { date: "2014-03-15" }
    assert_response :unauthorized
  end

  test "the signed-in user's own history only, in the shapes the frontend expects" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    user.update!(reporting_timezone: "UTC")
    scrobble(user, at: Time.utc(2014, 3, 15, 12), variant: variant(track: "Mine", artist: "My Band"))
    scrobble(user, at: Time.utc(2015, 3, 15, 12), variant: variant(track: "Mine again", artist: "My Band"))
    other = history_user("other")
    scrobble(other, at: Time.utc(2014, 3, 15, 13), variant: variant(track: "Theirs", artist: "Their Band"))
    scrobble(other, at: Time.utc(2016, 3, 15, 13), variant: variant(track: "Theirs", artist: "Their Band"))

    get "/api/calendar"
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[coverage firstDay lastDay months years], body.keys.sort
    assert_equal [ "2014-03-15", "2015-03-15" ], body.values_at("firstDay", "lastDay")

    get "/api/calendar", params: { from: "2014-03-01", to: "2014-03-31" }
    assert_response :ok
    assert_equal [ { "date" => "2014-03-15", "scrobbles" => 1 } ], response.parsed_body["days"]

    get "/api/plays", params: { period: "day:2014-03-15" }
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[coverage nextCursor period plays total], body.keys.sort
    assert_equal [ "Mine" ], body["plays"].map { |p| p.dig("track", "name") }
    assert_equal %w[album artist date id playedAt time track], body["plays"].first.keys.sort
    assert_equal "no-store", response.headers["Cache-Control"]

    get "/api/on-this-day", params: { date: "2015-03-15" }
    assert_response :ok
    body = response.parsed_body
    assert_equal [ "2014-03-15" ], body["years"].map { |y| y["date"] }, "no 2016: that year is someone else's history"
    assert_equal [ "My Band" ], body["years"].first["topArtists"].map { |a| a["name"] }
  end

  test "input it can't read is refused" do
    sign_in_via_lastfm(username: "listener")
    { "/api/calendar" => { from: "2014-03-01", to: "2014-02-01" }, "/api/plays" => { period: "day:2014-13-01" },
      "/api/on-this-day" => { date: "yesterday" } }.each do |path, params|
      get path, params: params
      assert_response :bad_request, path
    end
    get "/api/calendar", params: { from: "2014-01-01", to: "2016-01-01" }
    assert_response :bad_request
    get "/api/plays", params: { period: "day:2014-03-15", cursor: "nonsense" }
    assert_response :bad_request
    assert_equal "invalid_cursor", response.parsed_body["error"]
  end
end

# GET /api/genres/:slug. Synthetic data only.
class GenresApiTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  test "a genre's detail for the signed-in user only; unknown genres and periods refused" do
    get "/api/genres/pop"
    assert_response :unauthorized

    Genres::Seed.new.apply!
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    scrobble(user, at: Time.utc(2014, 3, 15, 12), variant: variant(track: "Mine", artist: "My Band"))
    scrobble(history_user("other"), at: Time.utc(2014, 3, 15, 12), variant: variant(track: "Theirs", artist: "Their Band"))

    get "/api/genres/pop", params: { period: "year:2014" }
    assert_response :ok
    body = response.parsed_body
    assert_equal %w[allocated byYear genre methodology period plays reach share subgenres topArtists topTracks unclassifiedShare], body.keys.sort
    assert_equal 1, body["plays"], "only this user's plays"
    get "/api/genres/nonsense"
    assert_response :not_found
    get "/api/genres/pop", params: { period: "year:20x4" }
    assert_response :bad_request
  end
end
