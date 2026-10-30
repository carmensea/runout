require "test_helper"

# Fixtures mirror the live response shape recorded in docs/lastfm-api-findings.md.
class Lastfm::RecentTracksPageTest < ActiveSupport::TestCase
  def entry(uts:, artist: "Artist", track: "Track", album: "Album", artist_mbid: "", track_mbid: "", album_mbid: "")
    { "artist" => { "mbid" => artist_mbid, "#text" => artist }, "streamable" => "0", "image" => [], "mbid" => track_mbid,
      "album" => { "mbid" => album_mbid, "#text" => album }, "name" => track, "url" => "https://www.last.fm/music/x",
      "date" => { "uts" => uts.to_s, "#text" => "01 Jan 2020, 00:00" } }
  end

  def body(tracks, page: 1, per_page: 200, total_pages: 1, total: nil)
    { "recenttracks" => { "track" => tracks, "@attr" => { "user" => "listener", "page" => page.to_s, "perPage" => per_page.to_s,
                                                          "totalPages" => total_pages.to_s, "total" => (total || tracks.size).to_s } } }
  end

  test "parses @attr counts given as strings" do
    page = Lastfm::RecentTracksPage.parse(body([ entry(uts: 1) ], page: 3, per_page: 200, total_pages: 1047, total: 209_350))
    assert_equal [ 3, 200, 1047, 209_350 ], [ page.page, page.per_page, page.total_pages, page.total ]
  end

  test "parses a dated play, keeping strings exactly as received" do
    page = Lastfm::RecentTracksPage.parse(body([ entry(uts: 1_199_145_600, artist: "  Sigur Rós ", track: "Hoppípolla", album: "Takk...",
                                                       artist_mbid: "f6f2326f-6b25-4170-b89d-e235b25508e8") ]))
    play = page.scrobbles.sole
    assert_equal Time.at(1_199_145_600).utc, play.played_at
    assert_equal "  Sigur Rós ", play.artist, "no trimming or normalisation"
    assert_equal "Hoppípolla", play.track
    assert_equal "Takk...", play.album
    assert_equal "f6f2326f-6b25-4170-b89d-e235b25508e8", play.artist_mbid
    assert_nil play.track_mbid, "empty MBIDs become nil"
  end

  test "accepts a single track object instead of an array" do
    page = Lastfm::RecentTracksPage.parse(body(entry(uts: 1)))
    assert_equal 1, page.scrobbles.size
  end

  test "excludes the now-playing entry, which has no date" do
    now_playing = entry(uts: 0).except("date").merge("@attr" => { "nowplaying" => "true" })
    page = Lastfm::RecentTracksPage.parse(body([ now_playing, entry(uts: 5) ]))
    assert page.now_playing
    assert_equal [ 5 ], page.scrobbles.map { |s| s.played_at.to_i }
    assert_equal 0, page.undated_count
  end

  test "counts undated rows instead of silently dropping them" do
    page = Lastfm::RecentTracksPage.parse(body([ entry(uts: 5), entry(uts: 0).except("date") ]))
    assert_equal 1, page.scrobbles.size
    assert_equal 1, page.undated_count
  end

  test "keeps same-second plays as separate rows, in the order received" do
    page = Lastfm::RecentTracksPage.parse(body([ entry(uts: 9, track: "B"), entry(uts: 9, track: "A") ]))
    assert_equal %w[B A], page.scrobbles.map(&:track)
  end

  test "reads extended artist nodes, which use name instead of #text" do
    extended = entry(uts: 1).merge("artist" => { "name" => "Extended Artist", "mbid" => "" })
    assert_equal "Extended Artist", Lastfm::RecentTracksPage.parse(body([ extended ])).scrobbles.sole.artist
  end

  test "an empty range has no rows and zero totals" do
    page = Lastfm::RecentTracksPage.parse(body([], total_pages: 0, total: 0))
    assert_empty page.scrobbles
    assert_equal [ 0, 0 ], [ page.total, page.total_pages ]
  end

  test "a response without recenttracks is a bad response" do
    assert_raises(Lastfm::Error::BadResponse) { Lastfm::RecentTracksPage.parse({ "user" => {} }) }
  end
end
