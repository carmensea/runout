require "test_helper"

# MusicBrainz IDs are enrichment, not the identity of a play: Last.fm can report different IDs for
# the same play from one request to the next (first real import, 2026-10-30). Two reads with the
# same plays validate; a disputed ID is stored as unresolved, with its candidates recorded; every
# other guarantee holds. Synthetic data only.
class HistoryImport::MbidDisputesTest < ActiveSupport::TestCase
  include HistoryHelpers

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze
  T = Time.utc(2014, 3, 15, 20)
  X = "11111111-1111-4111-8111-111111111111".freeze
  Y = "22222222-2222-4222-8222-222222222222".freeze
  A = "33333333-3333-4333-8333-333333333333".freeze
  B = "44444444-4444-4444-8444-444444444444".freeze
  Play = FakeRecentTracks::Play

  setup do
    @user = history_user
    @user.update!(reporting_timezone: "UTC")
    @window = window(@user, from: MARCH[0], to: MARCH[1])
    @client = stub_client(**Lastfm::Client::BACKGROUND_OPTIONS)
    @fake = FakeRecentTracks.history(count: 0, ending: Time.utc(2014, 3, 31, 23), same_second_every: nil).install(self)
  end

  def play(at, track = "Song", artist: "Artist", album: "Album", artist_mbid: "", track_mbid: "", album_mbid: "")
    Play.new(played_at: at, artist: artist, track: track, album: album, artist_mbid: artist_mbid, track_mbid: track_mbid, album_mbid: album_mbid)
  end

  # One request per complete read here: `changes` is applied to the plays before the second read.
  def second_read(&changes)
    @fake.before_request = ->(n, fake) { changes.call(fake) if n == 2 }
  end

  def validate(window = @window) = HistoryImport::WindowValidator.new(window: window, client: @client, username: "listener").call

  def staged = ImportWindowRow.joins(:import_window_fetch).where(import_window_fetches: { import_window_id: @window.id }).order(:played_at, :position)

  def commit(window = @window) = HistoryImport::WindowCommitter.new(window: window).call

  def ids(rows) = rows.map { |r| [ r.artist_mbid, r.album_mbid, r.track_mbid ] }

  test "the same play with a different recording ID validates, without the disputed ID" do
    @fake.add(play(T, track_mbid: X, artist_mbid: A, album_mbid: B))
    @fake.add(play(T + 60, "Steady", track_mbid: Y))
    second_read { |fake| fake.replace_at(fake.plays.index { |p| p.track == "Song" }, track_mbid: Y) }
    result = validate
    assert_equal :validated, result.status, result.detail
    assert_equal 2, @fake.requests, "settled on the first comparison"
    assert_equal [ [ A, B, nil ], [ nil, nil, Y ] ], ids(staged), "the other IDs are kept; the stable one too"
    assert_equal [ "Artist", "Song", "Album", T ], staged.first.slice(:artist_name, :track_name, :album_name, :played_at).values

    dispute = MbidDispute.sole
    assert_equal [ "track", "Artist", "Song", [ X, Y ].sort, 1 ], dispute.slice(:level, :artist_name, :title, :candidate_mbids, :occurrences).values
    assert_equal @window.id, dispute.first_import_window_id
  end

  test "an ID present in one read and missing in the other is unresolved" do
    @fake.add(play(T, track_mbid: X))
    second_read { |fake| fake.replace_at(0, track_mbid: "") }
    assert_equal :validated, validate.status
    assert_equal [ [ nil, nil, nil ] ], ids(staged)
    assert_equal [ X ], MbidDispute.sole.candidate_mbids
  end

  test "artist and album IDs that disagree are unresolved at their own level" do
    @fake.add(play(T, artist_mbid: A, album_mbid: B, track_mbid: X))
    second_read { |fake| fake.replace_at(0, artist_mbid: B, album_mbid: A) }
    assert_equal :validated, validate.status
    assert_equal [ [ nil, nil, X ] ], ids(staged)
    assert_equal [ [ "album", "Album" ], [ "artist", nil ] ], MbidDispute.order(:level).pluck(:level, :title)
  end

  test "stable IDs are kept and record no dispute" do
    @fake.add(play(T, artist_mbid: A, album_mbid: B, track_mbid: X))
    assert_equal :validated, validate.status
    assert_equal [ [ A, B, X ] ], ids(staged)
    assert_equal 0, MbidDispute.count
  end

  test "different names or times still fail validation, whatever the IDs do" do
    @fake.add(play(T, track_mbid: X))
    @fake.before_request = ->(n, fake) { fake.replace_at(0, track: "Song #{n}", track_mbid: n.even? ? Y : X) }
    assert_equal :needs_review, validate.status
    assert_equal 0, staged.count

    other = window(@user, from: Time.utc(2014, 5, 1), to: Time.utc(2014, 6, 1))
    @fake.add(play(Time.utc(2014, 5, 2, 10), track_mbid: X))
    @fake.before_request = lambda do |n, fake|
      fake.remove_if { |p| p.played_at.month == 5 }
      fake.add(play(Time.utc(2014, 5, 2, 10, 0, n), track_mbid: X))
    end
    assert_equal :needs_review, validate(other).status, "the play moves a second each read"
    assert_equal 0, MbidDispute.count, "nothing recorded for reads that never settled"
  end

  test "a missing play still fails validation even when the totals match" do
    @fake.add(play(T, "One", track_mbid: X))
    @fake.add(play(T, "Two", track_mbid: Y))
    # Every other read, "Two" comes back as a second "One": same total, a play missing.
    @fake.before_request = ->(n, fake) { fake.replace_at(fake.plays.index { |p| p.track_mbid == Y }, track: n.even? ? "One" : "Two") }
    assert_equal :needs_review, validate.status
  end

  test "identical same-second plays: IDs swapped between them are kept; IDs that change are unresolved for all" do
    3.times { @fake.add(play(T, "Twice")) }
    @fake.replace_at(0, track_mbid: X)
    @fake.replace_at(1, track_mbid: Y)
    @fake.add(play(T, "Thrice", track_mbid: X))
    @fake.add(play(T, "Thrice", track_mbid: X))
    second_read do |fake|
      fake.replace_at(0, track_mbid: Y) # Twice: [X, Y, -] then [Y, X, -], the same IDs
      fake.replace_at(1, track_mbid: X)
      fake.replace_at(4, track_mbid: Y) # Thrice: [X, X] then [X, Y]
    end
    assert_equal :validated, validate.status
    twice = staged.where(track_name: "Twice")
    thrice = staged.where(track_name: "Thrice")
    assert_equal [ 3, 2 ], [ twice.count, thrice.count ], "every occurrence kept"
    assert_equal [ nil, X, Y ], twice.map(&:track_mbid).sort_by(&:to_s)
    assert_equal [ nil, nil ], thrice.map(&:track_mbid)
    assert_equal [ 0, 1 ], thrice.map(&:occurrence).sort
    assert_equal [ "Thrice", [ X, Y ], 2 ], MbidDispute.sole.slice(:title, :candidate_mbids, :occurrences).values
  end

  test "a different order between reads, with an ID dispute, still validates" do
    @fake.shuffle_same_second = true
    4.times { |i| @fake.add(play(T, "Song #{i}", track_mbid: i.zero? ? X : "")) }
    second_read { |fake| fake.replace_at(fake.plays.index { |p| p.track == "Song 0" }, track_mbid: Y) }
    assert_equal :validated, validate.status
    assert_equal 4, staged.count
    assert_equal 1, MbidDispute.count
  end

  test "committing is idempotent, and later reads that flip the ID don't change, add or dispute anything" do
    @fake.add(play(T, track_mbid: X))
    @fake.add(play(T, track_mbid: X))
    second_read { |fake| fake.replace_at(0, track_mbid: Y) }
    assert_equal :validated, validate.status
    assert_equal :committed, commit.status
    stored = -> { Scrobble.where(user: @user).order(:played_at, :seq).map { |s| [ s.played_at, s.seq, s.name_variant_id ] } }
    before = stored.call
    assert_equal 2, before.size

    # A recheck of the month: every read now says Y, which differs from what was stored.
    @fake.before_request = nil
    @fake.plays.each_index { |i| @fake.replace_at(i, track_mbid: Y) }
    @window.reload.update!(state: "pending", check_from: nil)
    assert_equal :validated, validate.status
    assert_equal :committed, commit.status
    assert_equal before, stored.call, "the same plays, the same slots and variants"
    assert_equal({ "matched" => 2, "added" => 0 }, @window.reload.last_check_summary)
    assert_equal [ 0, 0 ], [ ReconciliationDispute.count, ScrobbleRemoval.count ]
  end

  test "a disputed song is one track after matching, wherever its plays came from" do
    may = window(@user, from: Time.utc(2014, 5, 1), to: Time.utc(2014, 6, 1))
    june = window(@user, from: Time.utc(2014, 6, 1), to: Time.utc(2014, 7, 1))
    stage!(may, [ entry(Time.utc(2014, 5, 2), "Song", album: "Album", track_mbid: X),
                  entry(Time.utc(2014, 5, 3), "Song", album: "Album", track_mbid: X) ]) # consistent in May
    stage!(june, [ entry(Time.utc(2014, 6, 2), "Song", album: "Album", track_mbid: Y) ])  # consistent in June
    [ may, june ].each { |w| assert_equal :committed, commit(w).status }
    matcher = Catalogue::Matcher.new
    matcher.match_pending!
    assert_equal 2, Track.where(title: "Song").count, "before any dispute, two recording IDs are two recordings"

    # March: the reads disagree (X, then Y).
    @fake.add(play(T, track_mbid: X))
    second_read { |fake| fake.replace_at(0, track_mbid: Y) }
    assert_equal :validated, validate.status
    assert_equal :committed, commit.status
    assert_equal 3, NameVariant.where(match_version: nil).count, "every variant of the song is queued again"
    matcher.match_pending!

    track_ids = NameVariant.where(track_name: "Song").distinct.pluck(:track_id)
    assert_equal 1, track_ids.size, "one track for X, Y and the unresolved play"
    assert_nil Track.find(track_ids.sole).mbid, "the name-only track: no recording ID is asserted"
    assert_equal %w[name], NameVariant.where(track_name: "Song").distinct.pluck(:track_match)
    assert_equal [ X, Y, nil ].map(&:to_s).sort, NameVariant.where(track_name: "Song").pluck(:track_mbid).map(&:to_s).sort, "variants keep their IDs"
    assert_equal 2, Track.where.not(mbid: nil).count, "the recordings themselves aren't merged or removed"
    assert CatalogueReview.open.where(level: "track", kind: "possible_match").exists?, "a person can still link it to a recording"

    o = Analytics::Overview.new(user: @user, period: Analytics::Period.parse("year:2014", time_zone: "UTC")).call
    assert_equal [ [ "Song", 4 ] ], o[:top][:tracks].map { |t| [ t[:name], t[:scrobbles] ] }
    assert_equal [ [ "Artist", 4 ] ], o[:top][:artists].map { |t| [ t[:name], t[:scrobbles] ] }
    assert_equal 1, o[:stats][:uniqueTracks]
  end

  test "a different song with a recording ID that was disputed elsewhere keeps using it" do
    MbidDispute.record!([ HistoryImport::Snapshot::IdConflict.new(level: "track", artist_name: "Artist", title: "Song", played_at: T, mbids: [ X ]) ],
                        window: @window)
    other = variant(artist: "Artist", track: "Other Song", album: "Album", track_mbid: X)
    Catalogue::Matcher.new.match!(other)
    assert_equal [ "mbid", X ], [ other.reload.track_match, other.track.mbid ]
  end

  test "a manual decision is never overridden by a dispute" do
    v = variant(artist: "Artist", track: "Song", album: "Album", track_mbid: X)
    matcher = Catalogue::Matcher.new
    matcher.match!(v)
    Catalogue::Decisions.assign!(v.reload, :track, v.track, by: @user)
    MbidDispute.record!([ HistoryImport::Snapshot::IdConflict.new(level: "track", artist_name: "Artist", title: "Song", played_at: T, mbids: [ X, Y ]) ],
                        window: @window)
    matcher.match_pending!
    assert_equal [ "manual", X ], [ v.reload.track_match, v.track.mbid ]
  end

  test "recording a dispute again merges candidates and counts occurrences" do
    conflict = ->(mbids) { HistoryImport::Snapshot::IdConflict.new(level: "track", artist_name: "Artist", title: "Song", played_at: T, mbids: mbids) }
    MbidDispute.record!([ conflict.([ X, Y ]) ], window: @window)
    MbidDispute.record!([ conflict.([ Y ]), conflict.([ A ]) ], window: @window)
    assert_equal [ [ A, X, Y ].sort, 3 ], MbidDispute.sole.slice(:candidate_mbids, :occurrences).values
  end

  test "with history storage off, no dispute is recorded" do
    Rails.configuration.x.history_import_enabled = "false"
    conflict = HistoryImport::Snapshot::IdConflict.new(level: "track", artist_name: "Artist", title: "Song", played_at: T, mbids: [ X ])
    assert_raises(HistoryImport::DisabledError) { MbidDispute.record!([ conflict ], window: @window) }
    assert_equal 0, MbidDispute.count
  end
end
