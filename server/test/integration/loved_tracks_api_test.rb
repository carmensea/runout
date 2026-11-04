require "test_helper"

# GET /api/loved-tracks: the signed-in user's loved songs with their listening, by the shared
# identity rules (src/data/types.ts LovedLibrary). Synthetic data only.
class LovedTracksApiTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  NOW = Time.utc(2026, 11, 4, 12)

  def love!(user, variant, at:, **attrs)
    Catalogue::Matcher.new.match!(variant)
    LovedTrack.create!(user: user, name_variant: variant, source: "lastfm", loved_at: at, source_url: "https://www.last.fm/x", **attrs)
  end

  test "needs a signed-in user, and a connected account" do
    get "/api/loved-tracks"
    assert_response :unauthorized
  end

  test "each loved song carries its loved date, its plays by shared identity, and how it reaches the catalogue" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    played = variant(track: "Song", artist: "Band", album: "LP")
    Catalogue::Matcher.new.match!(played)
    scrobble(user, at: Time.utc(2015, 1, 1), variant: played)
    scrobble(user, at: Time.utc(2020, 6, 1), variant: played)
    scrobble(user, at: NOW - 10.days, variant: played)
    scrobble(history_user("other"), at: NOW - 1.day, variant: played) # never counted for this user
    love!(user, variant(track: "Song", artist: "Band", album: ""), at: Time.utc(2012, 5, 6))
    love!(user, variant(track: "Never Played", artist: "Band", album: ""), at: Time.utc(2011, 1, 1))
    unloved = love!(user, variant(track: "Old Flame", artist: "Band", album: ""), at: Time.utc(2010, 1, 1), unloved_at: Time.utc(2013, 1, 1))

    travel_to NOW do
      get "/api/loved-tracks"
    end
    assert_response :ok
    body = response.parsed_body
    assert_equal 3, body["total"]
    assert_equal 90, body["recentDays"]
    assert_equal [ "Song", "Never Played", "Old Flame" ], body["tracks"].map { |t| t.dig("track", "name") }, "newest love first"

    song = body["tracks"][0]
    assert_equal "2012-05-06T00:00:00Z", song["lovedAt"]
    assert_equal({ "artist" => "Band", "track" => "Song" }, song["asLoved"])
    assert_equal played.reload.track_id.then { |id| "t#{id}" }, song.dig("track", "id"), "the same identity key as the plays"
    assert_equal "linked", song["link"]
    assert_equal 3, song["plays"]
    assert_equal "2015-01-01T00:00:00Z", song["firstPlayedAt"]
    assert_equal (NOW - 10.days).iso8601, song["lastPlayedAt"]
    assert_equal (NOW - 10.days).strftime("%Y-%m-%d"), song["lastPlayedDate"]
    assert_equal "2020-06-01T00:00:00Z", song["previousPlayedAt"], "the last play before the recent window"
    assert_equal 3, song["namePlays"]
    assert_equal "https://www.last.fm/x", song["url"]

    never = body["tracks"][1]
    assert_equal 0, never["plays"]
    assert_nil never["lastPlayedAt"]
    assert_equal 0, never["namePlays"]

    assert_equal unloved.unloved_at.iso8601, body["tracks"][2]["unlovedAt"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "a song whose name alone fits an identified track is held for review, and plays under its names are still reported" do
    sign_in_via_lastfm(username: "listener")
    user = User.sole
    identified = variant(track: "Should've Known Better", artist: "Band", album: "LP", artist_mbid: "0a1b2c3d-0000-4000-8000-000000000001", track_mbid: "0a1b2c3d-0000-4000-8000-000000000002")
    Catalogue::Matcher.new.match!(identified)
    scrobble(user, at: Time.utc(2019, 1, 1), variant: identified)
    love!(user, variant(track: "Should've Known Better", artist: "Band", album: ""), at: Time.utc(2018, 1, 1))

    get "/api/loved-tracks"
    track = response.parsed_body["tracks"].sole
    assert_equal "review", track["link"]
    assert_equal 0, track["plays"], "not counted as the identified track's plays until a person decides"
    assert_equal 1, track["namePlays"], "but plays under the same names are visible"
    refute_equal "t#{identified.reload.track_id}", track.dig("track", "id")
  end
end
