require "test_helper"

# Time Machine's data: the calendar, the play list and "On this day" (Analytics::Calendar, Plays,
# OnThisDay). Synthetic data only.
class Analytics::TimeMachineTest < ActiveSupport::TestCase
  include HistoryHelpers

  NOW = Time.utc(2026, 10, 31, 12)

  setup do
    @user = history_user
    @user.update!(reporting_timezone: "America/Los_Angeles")
  end

  def play(at, track = "Track", artist: "Artist", album: "Album", user: @user, seq: 0)
    scrobble(user, at: at, seq: seq, variant: variant(track: track, artist: artist, album: album))
  end

  def committed(from, to, user: @user)
    window(user, from: from, to: to, state: "committed", validated_at: NOW, committed_at: NOW, committed_count: 0)
  end

  def calendar = Analytics::Calendar.new(user: @user, now: NOW)

  def period(raw) = Analytics::Period.parse(raw, time_zone: @user.reporting_timezone, today: NOW.to_date)

  def plays(raw, **options) = Analytics::Plays.new(user: @user, period: period(raw), now: NOW, **options).call

  def on(date) = Analytics::OnThisDay.new(user: @user, date: date, now: NOW).call

  # Every page of a period, following the cursors.
  def all_pages(raw, limit:)
    pages = [ plays(raw, limit: limit) ]
    pages << plays(raw, limit: limit, cursor: pages.last[:nextCursor]) while pages.last[:nextCursor]
    pages
  end

  test "the history: first and latest local days, plays per month and year, without removed or other users' plays" do
    play(Time.utc(2014, 1, 1, 6), "New Year's Eve, local")    # 22:00 on 31 December 2013 in Los Angeles
    play(Time.utc(2014, 3, 15, 20), "March")
    play(Time.utc(2026, 9, 2, 3), "Latest, local 1 September")
    play(Time.utc(2026, 10, 1, 12), "Removed").update!(removed_at: NOW)
    play(Time.utc(2026, 10, 20), "Someone else's", user: history_user("other"))

    h = calendar.history
    assert_equal [ "2013-12-31", "2026-09-01" ], h.values_at(:firstDay, :lastDay), "local days, the latest with a play, not today"
    assert_equal [ { key: "2013", scrobbles: 1 }, { key: "2014", scrobbles: 1 }, { key: "2026", scrobbles: 1 } ], h[:years]
    assert_equal %w[2013-12 2014-03 2026-09], h[:months].map { |m| m[:key] }
  end

  test "an empty history has no days and no coverage" do
    assert_equal({ firstDay: nil, lastDay: nil, years: [], months: [], coverage: { status: "none", missing: [] } }, calendar.history)
  end

  test "plays per local day: inclusive range, local boundaries, daylight saving days whole, coverage of the rest" do
    committed(Time.utc(2014, 3, 1), Time.utc(2014, 4, 1))
    play(Time.utc(2014, 3, 9, 7, 59), "Before midnight")      # 23:59 PST on 8 March
    play(Time.utc(2014, 3, 9, 8, 0), "Midnight")              # 00:00 PST on 9 March
    play(Time.utc(2014, 3, 10, 6, 59), "End of a 23-hour day") # 23:59 PDT on 9 March
    play(Time.utc(2014, 3, 10, 7, 0), "Next day")             # 00:00 PDT on 10 March

    d = calendar.days(Date.new(2014, 3, 8), Date.new(2014, 3, 10))
    assert_equal [ [ "2014-03-08", 1 ], [ "2014-03-09", 2 ], [ "2014-03-10", 1 ] ], d[:days].map(&:values)
    assert_equal "complete", d[:coverage][:status]

    march = calendar.days(Date.new(2014, 3, 1), Date.new(2014, 3, 31))
    assert_equal "partial", march[:coverage][:status], "the UTC month leaves the first evening hours of local March uncovered"
    assert_equal [ [ "2014-03-31", "2014-03-31", true, false ] ], march[:coverage][:missing].map { |m| m.values_at(:from, :to, :partialFrom, :partialTo) }
    assert_equal "none", calendar.days(Date.new(2015, 6, 1), Date.new(2015, 6, 30))[:coverage][:status]

    assert_raises(ArgumentError) { calendar.days(Date.new(2014, 3, 2), Date.new(2014, 3, 1)) }
    assert_raises(ArgumentError) { calendar.days(Date.new(2014, 1, 1), Date.new(2015, 2, 5)) }
    assert_equal 400, (Analytics::Calendar::MAX_DAYS)
  end

  test "a day's plays in order, with local times and the exact strings, repeats and same-second plays each listed" do
    at = Time.utc(2014, 3, 15, 20) # 13:00 PDT
    play(at, "  Spaced  Title ", artist: "the cure", album: "")
    play(at, "  Spaced  Title ", artist: "the cure", album: "", seq: 1) # the same play twice in one second
    play(at - 3600, "Earlier", artist: "Artist")
    play(at + 60, "Later", artist: "Artist", album: "Album")
    play(at + 120, "Removed").update!(removed_at: NOW)
    play(at, "Theirs", user: history_user("other"))

    r = plays("day:2014-03-15")
    assert_equal 4, r[:total]
    assert_equal [ "12:00:00", "13:00:00", "13:00:00", "13:01:00" ], r[:plays].map { |p| p[:time] }
    assert_equal [ "Earlier", "  Spaced  Title ", "  Spaced  Title ", "Later" ], r[:plays].map { |p| p.dig(:track, :name) }, "strings as scrobbled"
    assert_equal "the cure", r[:plays][1].dig(:artist, :name)
    assert_nil r[:plays][1][:album], "no album when none was sent"
    assert_equal "Album", r[:plays][3].dig(:album, :name)
    assert_equal 4, r[:plays].map { |p| p[:id] }.uniq.size, "same-second plays are distinct rows"
    assert_equal %w[2014-03-15], r[:plays].map { |p| p[:date] }.uniq
    assert_nil r[:nextCursor]
  end

  test "identity keys are the Overview's, following merges" do
    v = variant(artist: "The Cure", track: "Lovesong", album: "Disintegration", artist_mbid: "69ee3720-a7cb-4402-b48d-a02c366f2bcf")
    Catalogue::Matcher.new.match!(v)
    scrobble(@user, at: Time.utc(2014, 3, 15, 20), variant: v.reload)
    o = Analytics::Overview.new(user: @user, period: period("day:2014-03-15")).call
    p = plays("day:2014-03-15")[:plays].sole
    assert_equal [ o[:top][:artists].sole[:id], o[:top][:tracks].sole[:id], o[:top][:albums].sole[:id] ],
                 [ p.dig(:artist, :id), p.dig(:track, :id), p.dig(:album, :id) ]
  end

  test "pages never repeat or skip a play, even inside one second, and later plays don't shift them" do
    at = Time.utc(2014, 3, 15, 20)
    5.times { |seq| play(at, "Same", seq: seq) }
    3.times { |i| play(at + 60 * (i + 1), "Next #{i}") }

    pages = all_pages("day:2014-03-15", limit: 2)
    ids = pages.flat_map { |p| p[:plays].map { |x| x[:id] } }
    assert_equal 4, pages.size
    assert_equal 8, ids.size
    assert_equal ids.uniq, ids
    assert_equal [ 8 ], pages.map { |p| p[:total] }.uniq

    first = plays("day:2014-03-15", limit: 3)
    play(at - 60, "Added before the cursor")
    play(at, "Same", seq: 5) # a sixth play in that second, after the cursor's slot
    rest = plays("day:2014-03-15", limit: 100, cursor: first[:nextCursor])
    assert_equal 0, (first[:plays].map { |x| x[:id] } & rest[:plays].map { |x| x[:id] }).size
    assert_equal 6, rest[:plays].size, "the first second's other two, the new sixth, and the three later plays"
  end

  test "a cursor that can't be read is refused" do
    [ "nonsense", Base64.urlsafe_encode64("x:1"), Base64.urlsafe_encode64("12") ].each do |bad|
      assert_raises(Analytics::Plays::InvalidCursor) { plays("day:2014-03-15", cursor: bad) }
    end
  end

  test "a confirmed empty day and a day without history are told apart" do
    committed(Time.utc(2014, 3, 1), Time.utc(2014, 4, 1))
    assert_equal [ 0, "complete" ], plays("day:2014-03-15").values_at(:total).push(plays("day:2014-03-15")[:coverage][:status])
    assert_equal "none", plays("day:2015-03-15")[:coverage][:status]
  end

  test "weeks, months, years and custom ranges list their plays across the boundaries" do
    play(Time.utc(2015, 1, 1, 6), "New Year's Eve, local") # 22:00 on 31 December 2014
    play(Time.utc(2015, 1, 1, 9), "New Year's Day")
    assert_equal 1, plays("year:2014")[:total]
    assert_equal 1, plays("month:2015-01")[:total]
    assert_equal 2, plays("week:2015-W01")[:total]
    assert_equal 2, plays("custom:2014-12-31..2015-01-01")[:total]
  end

  test "on this day: the same date in the other years, newest first, with top artists and track" do
    play(Time.utc(2014, 10, 31, 20), "Song", artist: "B")
    play(Time.utc(2014, 10, 31, 21), "Song", artist: "B")
    play(Time.utc(2014, 10, 31, 22), "Other", artist: "A")
    play(Time.utc(2016, 11, 1, 6), "Halloween night, local", artist: "C") # 23:00 PDT on 31 October
    play(Time.utc(2020, 10, 31, 12), "This year's own", artist: "D")
    committed(Time.utc(2015, 10, 1), Time.utc(2015, 11, 2))

    r = on(Date.new(2020, 10, 31))
    assert_equal %w[2019-10-31 2018-10-31 2017-10-31 2016-10-31 2015-10-31 2014-10-31], r[:years].map { |y| y[:date] },
                 "every year of the history, zero-play years included, but not the day's own"
    by_date = r[:years].index_by { |y| y[:date] }
    y2014 = r[:years].last
    assert_equal 3, y2014[:scrobbles]
    assert_equal [ [ "B", 2 ], [ "A", 1 ] ], y2014[:topArtists].map { |a| [ a[:name], a[:scrobbles] ] }
    assert_equal [ "Song", "B", 2 ], y2014[:topTrack].values_at(:name, :artist, :scrobbles)
    assert_equal [ 1, "C" ], [ by_date["2016-10-31"][:scrobbles], by_date["2016-10-31"][:topArtists].first[:name] ]
    assert_equal [ 0, "complete", nil ], by_date["2015-10-31"].values_at(:scrobbles, :coverage, :topTrack), "a confirmed empty day"
    assert_equal [ 0, "none" ], by_date["2018-10-31"].values_at(:scrobbles, :coverage), "no plays, and nothing known about it"
    assert_equal "none", y2014[:coverage], "plays exist, but the day isn't imported as complete"
  end

  test "on this day: 29 February only in leap years, and a 25-hour day is whole" do
    play(Time.utc(2012, 2, 29, 20))
    play(Time.utc(2013, 3, 1, 20))
    play(Time.utc(2016, 2, 29, 20))
    play(Time.utc(2019, 2, 28, 20))
    r = on(Date.new(2020, 2, 29))
    assert r[:leapDay]
    assert_equal %w[2016-02-29 2012-02-29], r[:years].map { |y| y[:date] }

    play(Time.utc(2014, 11, 2, 8, 30), "01:30 PDT")
    play(Time.utc(2014, 11, 2, 9, 30), "01:30 PST, an hour later")
    play(Time.utc(2014, 11, 3, 7, 30), "23:30 PST")
    assert_equal 3, on(Date.new(2019, 11, 2))[:years].find { |y| y[:date] == "2014-11-02" }[:scrobbles]
  end

  test "on this day leaves out years still to come, and is empty without history" do
    assert_equal [], on(Date.new(2026, 10, 31))[:years]
    play(Time.utc(2025, 12, 1))
    assert_equal [], on(Date.new(2026, 12, 1))[:years].select { |y| y[:date] > "2026-10-31" }
  end
end
