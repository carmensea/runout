require "test_helper"

class HistoryImport::SnapshotTest < ActiveSupport::TestCase
  Entry = HistoryImport::Snapshot::Entry

  def entry(at, track = "Track", artist: "Artist", album: "Album")
    Entry.new(played_at: Time.at(at).utc, artist: artist, artist_mbid: nil, track: track, track_mbid: nil, album: album, album_mbid: nil)
  end

  def snap(entries) = HistoryImport::Snapshot.new(entries: entries, reported_total: entries.size, total_pages: 1)

  test "order doesn't matter; contents and counts do" do
    a = snap([ entry(1, "A"), entry(1, "B"), entry(2) ])
    b = snap([ entry(2), entry(1, "B"), entry(1, "A") ])
    assert a.same_contents?(b)
  end

  test "identical plays are counted, not collapsed (a multiset, not a set)" do
    two = snap([ entry(1), entry(1) ])
    one = snap([ entry(1) ])
    assert_not two.same_contents?(one)
    assert_equal({ entry(1) => 2 }, two.multiset)
  end

  test "same total, different contents is not the same snapshot" do
    a = snap([ entry(1, "A"), entry(2, "B") ])
    b = snap([ entry(1, "A"), entry(2, "B (Remastered)") ])
    assert_equal a.size, b.size
    assert_not a.same_contents?(b)
    assert_equal({ only_in_first: 1, only_in_second: 1, first_size: 2, second_size: 2 }, a.difference_summary(b))
  end

  test "exact strings matter: case and spacing differences are different plays" do
    assert_not snap([ entry(1, "Track") ]).same_contents?(snap([ entry(1, "track") ]))
    assert_not snap([ entry(1, "Track") ]).same_contents?(snap([ entry(1, "Track ") ]))
  end

  test "staging rows number positions within each second and occurrences of identical plays" do
    rows = snap([ entry(5, "A"), entry(5, "A"), entry(5, "B"), entry(9, "A") ]).staging_rows
    assert_equal [ [ 0, 0 ], [ 1, 1 ], [ 2, 0 ], [ 0, 0 ] ], rows.map { |r| [ r[:position], r[:occurrence] ] }
    assert_equal rows[0][:variant_hash], rows[1][:variant_hash]
    assert_equal "Album", rows.first[:album_name]
  end
end
