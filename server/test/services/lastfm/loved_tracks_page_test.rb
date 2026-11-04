require "test_helper"

class Lastfm::LovedTracksPageTest < ActiveSupport::TestCase
  def body(tracks, total: tracks.size, pages: 1, page: 1)
    { "lovedtracks" => { "track" => tracks, "@attr" => { "user" => "listener", "page" => page.to_s, "perPage" => "1000", "totalPages" => pages.to_s, "total" => total.to_s } } }
  end

  def entry(name, artist, uts: 1_262_304_000, mbid: "", artist_mbid: "")
    { "name" => name, "mbid" => mbid, "url" => "https://www.last.fm/music/#{artist}/_/#{name}", "date" => { "uts" => uts.to_s, "#text" => "x" },
      "artist" => { "name" => artist, "mbid" => artist_mbid, "url" => "https://www.last.fm/music/#{artist}" } }
  end

  test "keeps strings exactly, turns empty MBIDs into nil and reads the loved date" do
    page = Lastfm::LovedTracksPage.parse(body([ entry(" Song ", "The Band", mbid: "0a1b2c3d-0000-4000-8000-000000000001") ], total: 859, pages: 2))
    assert_equal [ 1, 1000, 2, 859 ], [ page.page, page.per_page, page.total_pages, page.total ]
    loved = page.tracks.sole
    assert_equal " Song ", loved.track_name
    assert_equal "The Band", loved.artist_name
    assert_nil loved.artist_mbid
    assert_equal "0a1b2c3d-0000-4000-8000-000000000001", loved.track_mbid
    assert_equal Time.utc(2010, 1, 1), loved.loved_at
    assert_equal 0, page.malformed_count
  end

  test "a single track object, and malformed entries counted rather than dropped silently" do
    page = Lastfm::LovedTracksPage.parse(body(entry("Only", "One")))
    assert_equal 1, page.tracks.size
    bad = Lastfm::LovedTracksPage.parse(body([ entry("", "Band"), entry("Song", "Band").merge("date" => nil), "junk", entry("Fine", "Band") ]))
    assert_equal [ "Fine" ], bad.tracks.map(&:track_name)
    assert_equal 3, bad.malformed_count
  end

  test "a response without lovedtracks is a bad response" do
    assert_raises(Lastfm::Error::BadResponse) { Lastfm::LovedTracksPage.parse({ "error" => 6 }) }
  end
end
