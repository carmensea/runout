require "test_helper"

# The music diary (docs/milestone-5-plan.md §4, built as Memories): memories belong to one user and
# one catalogue song, read through the song's merge chain; dates about the memory stay apart from
# when it was written; nobody else's memories can be read, searched, changed or deleted, and
# nothing of them reaches logs, analytics or another account's caches. Fictional songs and words.
class MemoriesTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  setup do
    sign_in_via_lastfm(username: "listener")
    @user = User.sole
    @song = play!(@user, track: "Harbour Lights", artist: "The Lanterns", album: "Night Ferry", at: Time.utc(2014, 3, 15, 20))
    play!(@user, track: "Harbour Lights", artist: "The Lanterns", album: "Night Ferry", at: Time.utc(2019, 7, 1, 9))
  end

  # A play of a song, linked to the catalogue the usual way; returns the song's key.
  def play!(user, track:, artist:, album:, at:)
    v = variant(track: track, artist: artist, album: album)
    Catalogue::Matcher.new.match!(v)
    scrobble(user, at: at, variant: v)
    "t#{v.reload.track.resolved.id}"
  end

  def json = response.parsed_body
  def write(song, body, **rest) = post("/api/memories", params: { song: song, body: body, **rest }.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json"))
  def patch_memory(id, **attrs) = patch("/api/memories/#{id}", params: attrs.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json"))

  test "a memory is written about a song, read back with it, edited, and deleted; its own date stays apart from when it was written" do
    travel_to Time.utc(2026, 11, 7, 12) do
      write(@song, "The ferry crossing the first winter I lived by the water.", rememberedOn: "2014-03-15", rememberedLabel: "first winter by the water")
    end
    assert_response :created
    memory = json
    assert_equal [ @song, "Harbour Lights", "The Lanterns", "2014-03-15", "first winter by the water", "2026-11-07T12:00:00Z" ],
                 [ memory["song"]["id"], memory["song"]["name"], memory["song"]["artist"]["name"], memory["rememberedOn"], memory["rememberedLabel"], memory["createdAt"] ]

    get "/api/tracks/#{@song}"
    assert_response :ok
    assert_equal [ "Harbour Lights", 2, "2014-03-15T20:00:00Z", "2019-07-01T09:00:00Z", [ { "year" => 2014, "plays" => 1 }, { "year" => 2019, "plays" => 1 } ] ],
                 [ json["name"], json["plays"]["total"], json["plays"]["firstPlayedAt"], json["plays"]["lastPlayedAt"], json["plays"]["byYear"] ]
    assert_equal [ memory["id"] ], json["memories"].map { |m| m["id"] }
    assert_equal "no-store", response.headers["Cache-Control"]

    travel_to Time.utc(2026, 11, 8, 9) do
      patch_memory(memory["id"], body: "The ferry crossing, every morning that winter.", rememberedOn: "", rememberedLabel: "winter 2014")
    end
    assert_response :ok
    assert_equal [ "The ferry crossing, every morning that winter.", nil, "winter 2014", "2026-11-07T12:00:00Z", "2026-11-08T09:00:00Z" ],
                 json.values_at("body", "rememberedOn", "rememberedLabel", "createdAt", "updatedAt")

    delete "/api/memories/#{memory['id']}", headers: same_origin_headers
    assert_response :no_content
    get "/api/tracks/#{@song}"
    assert_empty json["memories"]
    assert_equal 0, Memory.count
  end

  test "several memories about one song stay separate and in the order they were written; other songs have their own" do
    other = play!(@user, track: "Paper Boats", artist: "The Lanterns", album: "Night Ferry", at: Time.utc(2015, 1, 1))
    write(@song, "Driving around with my best friend.", rememberedLabel: "2012")
    write(@song, "Listened to this constantly after the move.")
    write(other, "The song from the end of that summer.", rememberedOn: "2015-08-30")
    get "/api/tracks/#{@song}"
    assert_equal [ "Driving around with my best friend.", "Listened to this constantly after the move." ], json["memories"].map { |m| m["body"] }
    get "/api/tracks/#{other}"
    assert_equal [ "The song from the end of that summer." ], json["memories"].map { |m| m["body"] }

    get "/api/memories"
    assert_equal 3, json["memories"].size
    assert_equal [ other, @song, @song ], json["memories"].map { |m| m["song"]["id"] }, "the journal, newest written first"
    get "/api/memories", params: { q: "SUMMER" }
    assert_equal [ "The song from the end of that summer." ], json["memories"].map { |m| m["body"] }
    get "/api/memories", params: { q: "lanterns" }
    assert_equal 3, json["memories"].size, "the artist's name matches too"
    get "/api/memories", params: { q: "paper boats" }
    assert_equal [ other ], json["memories"].map { |m| m["song"]["id"] }
  end

  test "a song the catalogue knows but this person never played can carry a memory; one the catalogue can't place cannot" do
    stranger = history_user("stranger")
    unplayed = play!(stranger, track: "Quiet Road", artist: "Dawn Chorus", album: "Early", at: Time.utc(2010, 5, 5))
    get "/api/tracks/#{unplayed}"
    assert_response :ok
    assert_equal [ 0, nil, [] ], [ json["plays"]["total"], json["plays"]["firstPlayedAt"], json["plays"]["byYear"] ]
    write(unplayed, "I knew this long before I had any way to count it.")
    assert_response :created

    write("m#{'0' * 32}", "A song with no catalogue identity yet.")
    assert_response :unprocessable_content
    assert_equal "song_not_identified", json["error"]
    get "/api/tracks/t999999"
    assert_response :not_found
    write(@song, "")
    assert_response :unprocessable_content
    write(@song, "x", rememberedOn: "not a date")
    assert_response :unprocessable_content
    assert_equal "invalid_date", json["error"]
  end

  test "two songs with the same title by different artists are two songs, each with its own memories" do
    twin = play!(@user, track: "Harbour Lights", artist: "Coastal", album: "Tides", at: Time.utc(2020, 2, 2))
    assert_not_equal @song, twin
    write(twin, "Not the Lanterns one: the cover from the radio.")
    get "/api/tracks/#{@song}"
    assert_empty json["memories"]
    get "/api/tracks/#{twin}"
    assert_equal [ "Not the Lanterns one: the cover from the radio." ], json["memories"].map { |m| m["body"] }
  end

  test "a memory follows its song through a catalogue merge, and the old key still opens the same song" do
    duplicate = play!(@user, track: "Harbour Lights (Remastered)", artist: "The Lanterns", album: "Night Ferry (Deluxe)", at: Time.utc(2021, 1, 1))
    write(duplicate, "The remaster, on repeat the week it came out.")
    from = Track.find(duplicate.delete_prefix("t"))
    into = Track.find(@song.delete_prefix("t"))
    Catalogue::Decisions.merge!(from, into, by: @user)

    get "/api/tracks/#{@song}"
    assert_equal [ "The remaster, on repeat the week it came out." ], json["memories"].map { |m| m["body"] }
    assert_equal 3, json["plays"]["total"], "the plays merged too"
    get "/api/tracks/#{duplicate}"
    assert_response :ok
    assert_equal @song, json["id"], "the old key resolves to the song it was merged into"
    get "/api/memories"
    assert_equal [ @song ], json["memories"].map { |m| m["song"]["id"] }
    assert_equal 1, Memory.count, "nothing copied, nothing lost"
  end

  test "another account sees, searches, edits and deletes none of this one's memories, even about the same song" do
    write(@song, "Mine, about the ferry.")
    mine = json["id"]
    other = User.create!(display_name: "other", reporting_timezone: "Europe/London")
    _, token = Session.start!(user: other, ip_address: "127.0.0.1", user_agent: "test")
    delete "/api/session", headers: same_origin_headers
    cookies[Authentication::COOKIE_NAME] = token

    get "/api/tracks/#{@song}"
    assert_response :ok
    assert_empty json["memories"]
    assert_equal 0, json["plays"]["total"], "and none of the other person's plays"
    get "/api/memories", params: { q: "ferry" }
    assert_empty json["memories"]
    patch_memory(mine, body: "rewritten by someone else")
    assert_response :not_found
    delete "/api/memories/#{mine}", headers: same_origin_headers
    assert_response :not_found
    assert_equal "Mine, about the ferry.", Memory.find(mine).body

    write(@song, "Theirs, about the same song.")
    assert_response :created
    get "/api/tracks/#{@song}"
    assert_equal [ "Theirs, about the same song." ], json["memories"].map { |m| m["body"] }
    assert_equal({ @user.id => 1, other.id => 1 }, Memory.group(:user_id).count)
  end

  test "memory text reaches no analytics answer and no log, and nothing works signed out" do
    write(@song, "The secret ferry sentence.")
    assert_response :created
    get "/api/overview"
    assert_response :ok
    assert_no_match(/secret ferry/, response.body)
    get "/api/search", params: { q: "secret ferry" }
    assert_response :ok
    assert_no_match(/secret ferry/, response.body)
    filtered = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter("body" => "secret", "rememberedLabel" => "secret", "song" => @song)
    assert_equal [ "[FILTERED]", "[FILTERED]", @song ], filtered.values_at("body", "rememberedLabel", "song"), "the log never carries the words"

    delete "/api/session", headers: same_origin_headers
    get "/api/memories"
    assert_response :unauthorized
    get "/api/tracks/#{@song}"
    assert_response :unauthorized
    write(@song, "nobody")
    assert_response :unauthorized
  end

  test "a song's cover follows the Overview's order of trust, and a song played with no album takes this person's inferred cover" do
    release = "11111111-1111-4111-8111-111111111111"
    other_release = "22222222-2222-4222-8222-222222222222"
    cover = ->(id, image) { MetadataArtwork.create!(provider: "coverartarchive", release_id: id, found_on: "release", image_id: image, thumbnail_250: "https://archive.org/#{image}-250.jpg", source_url: "https://coverartarchive.org/release/#{id}", fetched_at: Time.current) }
    cover.call(release, "verified")
    cover.call(other_release, "inferred")

    # An album-less listen (a scrobbler that sent no album), as ListenBrainz's mapping later inferred.
    loose = play!(@user, track: "Loose Song", artist: "The Lanterns", album: "", at: Time.utc(2022, 2, 2))
    InferredArtwork.create!(user: @user, subject_key: loose, release_id: other_release, status: "ok", observations: 1)
    get "/api/tracks/#{loose}"
    assert_equal "https://archive.org/inferred-250.jpg", json["artworkUrl"], "the song's own inferred cover"
    write(loose, "Heard only through the scrobbler.")
    get "/api/memories"
    assert_equal "https://archive.org/inferred-250.jpg", json["memories"].first["song"]["artworkUrl"]

    # The same song for another account: no inference of theirs, no cover.
    other = User.create!(display_name: "other", reporting_timezone: "Europe/London")
    scrobble(other, at: Time.utc(2022, 3, 3), variant: NameVariant.find_by!(track_name: "Loose Song"))
    _, token = Session.start!(user: other, ip_address: "127.0.0.1", user_agent: "test")
    delete "/api/session", headers: same_origin_headers
    cookies[Authentication::COOKIE_NAME] = token
    get "/api/tracks/#{loose}"
    assert_nil json["artworkUrl"]

    # Back as the first person: a verified release cover on the played album outranks an inferred one.
    delete "/api/session", headers: same_origin_headers
    sign_in_via_lastfm(username: "listener")
    Album.find_by!(title: "Night Ferry").update!(mbid: release)
    InferredArtwork.create!(user: @user, subject_key: "l#{Album.find_by!(title: 'Night Ferry').id}", release_id: other_release, status: "ok", observations: 2)
    get "/api/tracks/#{@song}"
    assert_equal "https://archive.org/verified-250.jpg", json["artworkUrl"]
  end

  test "deleting the account removes its memories and nothing of the catalogue" do
    write(@song, "Gone with the account.")
    tracks = Track.count
    delete "/api/account", params: { confirm_name: "listener" }.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
    assert_response :ok
    assert_equal [ 0, tracks ], [ Memory.count, Track.count ]
  end
end
