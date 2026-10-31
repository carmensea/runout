require "test_helper"

# Chained merges (A → B, then B → C) resolve to the end of the chain everywhere: the models, the
# matcher, the Overview and Search. Cycles are refused, and harmless if one exists anyway.
# Synthetic data only.
class Catalogue::MergeChainTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup do
    @user = history_user
    @user.update!(reporting_timezone: "UTC")
    @reviewer = history_user("reviewer")
    @matcher = Catalogue::Matcher.new
  end

  def overview(period = "year:2014")
    Analytics::Overview.new(user: @user, period: Analytics::Period.parse(period, time_zone: "UTC", today: Date.new(2026, 10, 31))).call
  end

  def search(q) = Analytics::Search.new(user: @user, query: q).call

  def matched(artist, track = "Track", album: "Album", **mbids)
    variant(artist: artist, track: track, album: album, **mbids).tap { |v| @matcher.match!(v) }.reload
  end

  def plays(v, count, day: 1)
    count.times { |i| scrobble(@user, at: Time.utc(2014, 3, day, 12, i), variant: v) }
  end

  # Three artists merged A → B, then B → C, each with plays on its own variant.
  #
  # merge! re-matches the variants after its transaction, and re-matching follows the whole
  # chain, so links normally end at C. With `stale:`, the Alpha and Beta variants are left linked
  # to A and B, as an interrupted re-match would leave them: the chain alone says they are C's.
  def chain_of_three(stale: true)
    a, b, c = %w[Alpha Beta Gamma].map { |name| matched(name, "#{name} song") }
    Catalogue::Decisions.assign!(a, :artist, a.artist, by: @reviewer)
    plays(a.reload, 2, day: 1)
    plays(b, 3, day: 2)
    plays(c, 4, day: 3)
    Catalogue::Decisions.merge!(a.artist, b.artist, by: @reviewer)
    Catalogue::Decisions.merge!(b.artist, c.artist, by: @reviewer)
    if stale
      a.update_columns(artist_id: a.artist_id)
      b.update_columns(artist_id: b.artist_id)
    end
    [ a.artist, b.artist, c.artist ]
  end

  test "a chain of merges resolves to its end, and each merge stays recorded" do
    a, b, c = chain_of_three
    assert_equal [ b, c, nil ], [ a.reload.merged_into, b.reload.merged_into, c.reload.merged_into ], "pointers are kept as decided"
    assert_equal [ c, c, c ], [ a, b, c ].map(&:resolved)

    # Re-matching moves every link to the end of the chain, and keeps the manual decision.
    NameVariant.find_each { |v| @matcher.match!(v) }
    alpha = NameVariant.find_by!(artist_name: "Alpha")
    assert_equal [ c.id, "manual" ], [ alpha.artist_id, alpha.artist_match ]
    assert_equal [ c.id ], NameVariant.distinct.pluck(:artist_id)

    sql = Catalogue::Roots.sql("artists")
    roots = ActiveRecord::Base.connection.select_rows("SELECT id, root_id FROM #{sql} r ORDER BY id").to_h
    assert_equal({ a.id => c.id, b.id => c.id }, roots)
  end

  test "the Overview counts a chain as one artist, under the final entity's name and id" do
    _a, _b, c = chain_of_three
    o = overview
    assert_equal 9, o[:stats][:scrobbles], "every play counted once"
    assert_equal 1, o[:stats][:uniqueArtists]
    assert_equal 1, o[:top][:totals][:artists]
    artist = o[:top][:artists].sole
    assert_equal [ "a#{c.id}", "Gamma", 9 ], [ artist[:id], artist[:name], artist[:scrobbles] ]
    assert_equal 3, artist[:tracksPlayed], "the three tracks stay three tracks"
    assert_equal 1, o[:discovery][:months].sum { |m| m[:newArtists] }, "first heard once, not three times"
    assert_equal [ [ "a#{c.id}", "2014-03-01", 9 ] ], o[:discovery][:firstHeard].map { |e| e.values_at(:id, :firstScrobble, :scrobbles) }
    assert_equal o, overview, "the same answer every time"
  end

  test "the Overview is the same before and after re-matching" do
    chain_of_three
    before = overview
    NameVariant.find_each { |v| @matcher.match!(v) }
    after = overview
    # Albums aren't compared: re-matching moves a name-only album under its new artist's album of
    # that name (albums are scoped to their artist), which is matching, not the chain.
    assert_equal before[:stats].values_at(:scrobbles, :uniqueArtists, :uniqueTracks), after[:stats].values_at(:scrobbles, :uniqueArtists, :uniqueTracks)
    assert_equal before[:top][:artists], after[:top][:artists]
  end

  [ true, false ].each do |stale|
    test "Search finds a chain as one artist under the final entity, by any of its names (stale links: #{stale})" do
      _a, _b, c = chain_of_three(stale: stale)
      %w[alpha beta gamma].each do |q|
        assert_equal [ { id: "a#{c.id}", name: "Gamma" } ], search(q)[:artists], "searching #{q}"
      end
      assert_equal search("gamma"), search("gamma")
    end
  end

  test "chains of tracks and albums resolve too" do
    v1 = matched("Artist", "Song (demo)", album: "Demos")
    v2 = matched("Artist", "Song (edit)", album: "Singles")
    v3 = matched("Artist", "Song", album: "Album")
    Catalogue::Decisions.assign!(v1, :track, v1.track, by: @reviewer)
    Catalogue::Decisions.assign!(v1, :album, v1.album, by: @reviewer)
    [ v1, v2, v3 ].each_with_index { |v, i| plays(v.reload, i + 1, day: i + 1) }
    Catalogue::Decisions.merge!(v1.track, v2.track, by: @reviewer)
    Catalogue::Decisions.merge!(v2.track, v3.track, by: @reviewer)
    Catalogue::Decisions.merge!(v1.album, v2.album, by: @reviewer)
    Catalogue::Decisions.merge!(v2.album, v3.album, by: @reviewer)
    v1.update_columns(track_id: v1.track_id, album_id: v1.album_id) # as an interrupted re-match leaves them

    o = overview
    assert_equal [ [ "t#{v3.track_id}", "Song", 6 ] ], o[:top][:tracks].map { |t| t.values_at(:id, :name, :scrobbles) }
    assert_equal [ [ "l#{v3.album_id}", "Album", 6 ] ], o[:top][:albums].map { |t| t.values_at(:id, :name, :scrobbles) }
    assert_equal [ 1, 1 ], [ o[:stats][:uniqueTracks], o[:top][:totals][:albums] ]
    assert_equal [ "t#{v3.track_id}" ], search("song demo")[:tracks].map { |t| t[:id] }
  end

  test "a merge that would make a cycle is refused, and nothing changes" do
    a, b, c = chain_of_three
    assert_raises(ArgumentError) { Catalogue::Decisions.merge!(c, a, by: @reviewer) }
    assert_nil c.reload.merged_into_id
    assert_raises(ActiveRecord::RecordInvalid) { c.update!(merged_into: a) }
    assert_raises(ActiveRecord::RecordInvalid) { b.update!(merged_into: b) }
    assert_equal [ c.id, nil ], [ b.reload.merged_into_id, c.reload.merged_into_id ]
  end

  test "a cycle written past the checks loses and double-counts nothing" do
    a, _b, c = chain_of_three
    c.update_column(:merged_into_id, a.id) # A → B → C → A, bypassing validation
    assert_equal [ a, c ], [ a.reload.resolved, c.reload.resolved ], "each stands for itself"

    o = overview
    assert_equal 9, o[:stats][:scrobbles]
    assert_equal 9, o[:top][:artists].sum { |e| e[:scrobbles] }
    assert_equal %w[Alpha Beta Gamma], o[:top][:artists].map { |e| e[:name] }.sort
    assert_equal o, overview
  end

  test "an ambiguous name is resolved by chained merges, and counted by name until then" do
    first = Artist.create!(name: "Twin")
    second = Artist.create!(name: "Twin")
    final = Artist.create!(name: "Twins", mbid: "55555555-5555-4555-8555-555555555555")
    v = matched("Twin")
    assert_equal "ambiguous", v.artist_match
    plays(v, 2)
    assert_match(/\An/, overview[:top][:artists].sole[:id], "grouped by its name while ambiguous")

    Catalogue::Decisions.merge!(first, second, by: @reviewer)
    Catalogue::Decisions.merge!(second, final, by: @reviewer)
    @matcher.match!(v)
    assert_equal [ final.id, "manual" ], [ v.reload.artist_id, v.artist_match ], "both names now lead to one artist"
    assert_equal [ [ "a#{final.id}", "Twins", 2 ] ], overview[:top][:artists].map { |e| e.values_at(:id, :name, :scrobbles) }
  end

  test "a long chain resolves in one query" do
    artists = Array.new(12) { |i| Artist.create!(name: "Name #{i}") }
    artists.each_cons(2) { |from, into| from.update!(merged_into: into) }
    v = variant(artist: "Name 0", track: "Track")
    v.update_columns(artist_id: artists.first.id, artist_match: "manual")
    plays(v, 1)
    assert_equal artists.last, artists.first.resolved
    assert_equal "a#{artists.last.id}", overview[:top][:artists].sole[:id]
  end
end
