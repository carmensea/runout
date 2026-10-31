require "test_helper"

# Milestone 3: the Overview from stored plays (Analytics::Overview). Synthetic data only.
class Analytics::OverviewTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup do
    @user = history_user
    @user.update!(reporting_timezone: "Europe/London")
  end

  def overview(period, user: @user, today: Date.new(2026, 10, 31))
    Analytics::Overview.new(user: user, period: Analytics::Period.parse(period, time_zone: user.reporting_timezone, today: today)).call
  end

  def play(at, track = "Track", artist: "Artist", album: "Album", user: @user, seq: 0)
    scrobble(user, at: at, seq: seq, variant: variant(track: track, artist: artist, album: album))
  end

  def matched(track:, artist:, album: "Album", **mbids)
    variant(track: track, artist: artist, album: album, **mbids).tap { |v| Catalogue::Matcher.new.match!(v) }.reload
  end

  test "plays are placed in the reporting timezone, across daylight saving changes" do
    # 30 March 2014, London: clocks go forward at 01:00 UTC.
    play(Time.utc(2014, 3, 29, 23, 30), "Saturday night") # 23:30 GMT on the 29th
    play(Time.utc(2014, 3, 30, 0, 30), "Before the change") # 00:30 GMT
    play(Time.utc(2014, 3, 30, 1, 30), "After the change")  # 02:30 BST
    day = overview("day:2014-03-30")
    assert_equal 2, day[:stats][:scrobbles]
    assert_equal [ 1, 0, 1 ], day[:habits][:byHour].first(3), "00:30 and 02:30 local; 01:xx doesn't exist that day"
    assert_equal 6, day[:habits][:byWeekday].index(2), "a Sunday (Monday first)"

    # 26 October 2014: clocks go back at 01:00 UTC, so 01:30 local happens twice.
    play(Time.utc(2014, 10, 26, 0, 30), "First 01:30")
    play(Time.utc(2014, 10, 26, 1, 30), "Second 01:30")
    assert_equal 2, overview("day:2014-10-26")[:habits][:byHour][1]
  end

  test "year, month, week and custom periods use local calendar boundaries" do
    @user.update!(reporting_timezone: "America/New_York")
    play(Time.utc(2015, 1, 1, 3), "New Year's Eve in New York") # 22:00 on 31 December 2014, local
    play(Time.utc(2015, 1, 1, 6), "New Year's Day")             # 01:00 on 1 January 2015
    assert_equal 1, overview("year:2014")[:stats][:scrobbles]
    assert_equal 1, overview("year:2015")[:stats][:scrobbles]
    assert_equal 1, overview("month:2014-12")[:stats][:scrobbles]
    assert_equal 2, overview("week:2015-W01")[:stats][:scrobbles], "ISO week 1 of 2015 starts on Monday 29 December 2014"
    assert_equal 2, overview("custom:2014-12-31..2015-01-01")[:stats][:scrobbles]
    assert_equal 0, overview("custom:2015-01-02..2015-01-05")[:stats][:scrobbles]
    assert_equal [ "2014", "2015" ], overview("all")[:activity][:year].map { |b| b[:key] }
  end

  test "the last 12 months are this month so far and the eleven before" do
    period = Analytics::Period.parse("l12", time_zone: "UTC", today: Date.new(2026, 10, 31))
    assert_equal [ Date.new(2025, 11, 1), Date.new(2026, 10, 31) ], [ period.from, period.to ]
    assert_raises(ArgumentError) { Analytics::Period.parse("month:2014-13", time_zone: "UTC") }
    assert_raises(ArgumentError) { Analytics::Period.parse("custom:2015-02-01..2015-01-01", time_zone: "UTC") }
  end

  test "same-second plays count separately; removed plays don't count; other users' plays never do" do
    at = Time.utc(2014, 3, 15, 20)
    v = variant(track: "Twice")
    scrobble(@user, at: at, seq: 0, variant: v)
    scrobble(@user, at: at, seq: 1, variant: v)
    play(Time.utc(2014, 3, 16), "Removed").update!(removed_at: Time.current)
    other = history_user("other")
    play(Time.utc(2014, 3, 17), "Someone else's", user: other)

    o = overview("month:2014-03")
    assert_equal 2, o[:stats][:scrobbles]
    assert_equal [ [ "Twice", 2 ] ], o[:top][:tracks].map { |t| [ t[:name], t[:scrobbles] ] }
    assert_equal [ { trackId: o[:top][:tracks].first[:id], name: "Twice", artist: "Artist", plays: 2, date: "2014-03-15" } ], o[:onRepeat]
  end

  test "artists are counted by catalogue identity; unmatched plays are kept and grouped by their names" do
    mbid = SecureRandom.uuid
    a = matched(track: "One", artist: "The Band", artist_mbid: mbid)
    b = matched(track: "Two", artist: "the band ", artist_mbid: mbid) # another spelling, same artist
    scrobble(@user, at: Time.utc(2014, 3, 1), variant: a)
    scrobble(@user, at: Time.utc(2014, 3, 2), variant: b)
    play(Time.utc(2014, 3, 3), "Unmatched song", artist: "Not Matched Yet")
    play(Time.utc(2014, 3, 4), "Another", artist: "not matched  yet") # same normalised name
    play(Time.utc(2014, 3, 5), "No album", artist: "Not Matched Yet", album: "")

    o = overview("month:2014-03")
    assert_equal 5, o[:stats][:scrobbles], "nothing dropped"
    assert_equal 2, o[:stats][:uniqueArtists]
    artists = o[:top][:artists].to_h { |e| [ e[:name], e ] }
    assert_equal 3, artists.fetch("Not Matched Yet")[:scrobbles]
    assert_equal 2, artists.fetch("The Band")[:scrobbles]
    assert_match(/\Aa\d+\z/, artists.fetch("The Band")[:id], "a catalogue id")
    assert_match(/\An\h{32}\z/, artists.fetch("Not Matched Yet")[:id], "a name-based id, stable across requests")
    assert_equal 2, artists.fetch("The Band")[:tracksPlayed]
    assert_equal 5, o[:stats][:uniqueTracks]
    assert_equal 2, o[:top][:totals][:albums], "one album per artist here; a play without an album name has none"
    assert_equal o[:top][:artists].map { |e| e[:id] }, overview("month:2014-03")[:top][:artists].map { |e| e[:id] }
  end

  test "activity buckets cover the whole period, zero months included, with each bucket's top artist" do
    play(Time.utc(2014, 1, 10), artist: "January")
    play(Time.utc(2014, 1, 11), artist: "January")
    play(Time.utc(2014, 1, 12), artist: "Other")
    play(Time.utc(2014, 3, 10), artist: "March")
    o = overview("year:2014")
    months = o[:activity][:month]
    assert_equal 12, months.size
    assert_equal [ "2014-01", 3, "January" ], months.first.values_at(:key, :scrobbles, :topArtist)
    assert_equal [ 0, nil ], months[1].values_at(:scrobbles, :topArtist)
    assert_equal 53, o[:activity][:week].size, "ISO weeks touching 2014"
    assert_nil overview("all")[:activity][:week], "weeks only for periods up to two years"
    assert_equal [ { key: "2014-01", scrobbles: 3 }, { key: "2014-03", scrobbles: 1 } ], o[:mostActiveMonths]
    assert_equal 12, o[:habits][:avgPerDayByMonth].size
    assert_in_delta 3 / 31.0, o[:habits][:avgPerDayByMonth][0], 0.01
  end

  test "top lists, trends and yearly ranks" do
    12.times { |i| play(Time.utc(2014, 1 + i, 1), "Hit", artist: "Top") }
    3.times { |i| play(Time.utc(2015, 1 + i, 1), "Song", artist: "Second") }
    play(Time.utc(2015, 6, 1), "Song", artist: "Top")
    o = overview("all")
    top = o[:top][:artists].first
    assert_equal [ "Top", 13, "2014-01-01", "2015-06-01" ], top.values_at(:name, :scrobbles, :firstScrobble, :latestScrobble)
    assert_equal 12, top[:trend].size
    assert_equal 13, top[:trend].sum, "the trend divides the period evenly"
    assert_equal [ 2014, 2015 ], o[:rankHistory][:years]
    assert_equal({ "Top" => [ 1, 2 ], "Second" => [ nil, 1 ] }, o[:rankHistory][:series].to_h { |s| [ s[:name], s[:ranks] ] })
  end

  test "discovery: new artists, exploration, first heard, back in rotation and rediscovered" do
    play(Time.utc(2010, 5, 1), artist: "Old Friend")
    play(Time.utc(2013, 1, 10), artist: "Steady")
    play(Time.utc(2014, 2, 1), artist: "Steady")
    play(Time.utc(2014, 3, 1), artist: "Old Friend")     # back after almost four years
    play(Time.utc(2014, 3, 5), artist: "Newcomer")
    play(Time.utc(2014, 3, 6), artist: "Newcomer")

    o = overview("year:2014")
    march = o[:discovery][:months].find { |m| m[:key] == "2014-03" }
    assert_equal 1, march[:newArtists], "Newcomer was first heard in March"
    assert_in_delta 2 / 3.0, march[:explorationShare], 0.001, "two of three March plays from artists first heard within 90 days"
    assert_equal [ [ "Newcomer", "2014-03-05", 2 ] ], o[:discovery][:firstHeard].map { |a| a.values_at(:name, :firstScrobble, :scrobbles) }
    assert_equal [ [ "Old Friend", 2010 ] ], o[:discovery][:rediscovered].map { |a| a.values_at(:name, :lastYearBefore) }
    back = o[:backInRotation].map { |r| r.values_at(:name, :awayMonths, :backMonth) }
    assert_equal [ [ "Old Friend", 45, "2014-03" ], [ "Steady", 12, "2014-02" ] ], back
  end

  test "an empty period: zeros, honest coverage, and the nearest months with plays" do
    play(Time.utc(2014, 1, 10))
    play(Time.utc(2014, 6, 10))
    o = overview("month:2014-03")
    assert_equal 0, o[:stats][:scrobbles]
    assert_nil o[:stats][:firstScrobbleDate]
    assert_equal [ { key: "2014-03", scrobbles: 0, topArtist: nil } ], o[:activity][:month]
    assert_empty o[:top][:artists]
    assert_equal [ "month:2014-01", "month:2014-06" ], o[:nearestWithData]
    assert_nil o[:genres], "not available yet (Milestone 4), never estimated"
    assert_nil o[:metadata]
    assert_nil o[:stats][:albumsWithoutArtwork]
  end

  test "coverage says when a period isn't fully imported, and which dates are missing" do
    @user.update!(reporting_timezone: "UTC") # import windows are UTC months; local dates shift with the timezone
    assert_equal({ status: "none", missing: [] }, overview("year:2014")[:coverage])
    window(@user, from: Time.utc(2014, 1, 1), to: Time.utc(2014, 6, 1), state: "committed", validated_at: Time.current,
                  committed_at: Time.current, committed_count: 0)
    window(@user, from: Time.utc(2014, 7, 1), to: Time.utc(2015, 1, 1), state: "committed", validated_at: Time.current,
                  committed_at: Time.current, committed_count: 0)
    assert_equal({ status: "complete", missing: [] }, overview("month:2014-03")[:coverage])
    year = overview("year:2014")[:coverage]
    assert_equal "partial", year[:status]
    assert_equal [ { from: "2014-06-01", to: "2014-06-30" } ], year[:missing]
    assert_equal "partial", overview("all")[:coverage][:status]
    assert_equal "none", overview("month:2014-06")[:coverage][:status]
  end

  test "comparison periods follow the same rules, zero periods included" do
    play(Time.utc(2014, 3, 1))
    a = overview("year:2014")
    b = overview("year:2011")
    assert_equal [ 1, 0 ], [ a[:stats][:scrobbles], b[:stats][:scrobbles] ]
    assert_equal a.keys, b.keys
    assert_equal 12, b[:activity][:month].size
  end
end
