require "test_helper"

# Missing coverage as local calendar dates (Analytics::Period.local_days, Overview coverage).
# Import windows and plays stay in UTC; only their display is local. Synthetic data only.
class Analytics::CoverageDatesTest < ActiveSupport::TestCase
  include HistoryHelpers

  def days(from, to, zone) = Analytics::Period.local_days(from...to, zone)

  def overview(user, period)
    Analytics::Overview.new(user: user, period: Analytics::Period.parse(period, time_zone: user.reporting_timezone, today: Date.new(2026, 10, 31))).call
  end

  def committed(user, from, to)
    window(user, from: from, to: to, state: "committed", validated_at: Time.current, committed_at: Time.current, committed_count: 0)
  end

  test "a UTC month in Pacific time: the evening before to the evening of its last day, both partial" do
    d = days(Time.utc(2014, 6, 1), Time.utc(2014, 7, 1), "America/Los_Angeles") # PDT, UTC-7
    assert_equal [ "2014-05-31", "2014-06-30", true, true ], d.values_at(:from, :to, :partialFrom, :partialTo)
    assert_equal [ "2014-06-01T00:00:00Z", "2014-07-01T00:00:00Z" ], d.values_at(:startsAt, :endsAt), "the instants stay UTC"

    winter = days(Time.utc(2014, 1, 1), Time.utc(2014, 2, 1), "America/Los_Angeles") # PST, UTC-8
    assert_equal [ "2013-12-31", "2014-01-31" ], winter.values_at(:from, :to)
  end

  test "the end is exclusive: an interval ending at local midnight doesn't touch the next day" do
    la = "America/Los_Angeles"
    whole_day = days(Time.utc(2014, 6, 1, 7), Time.utc(2014, 6, 2, 7), la) # local midnight to midnight
    assert_equal [ "2014-06-01", "2014-06-01", false, false ], whole_day.values_at(:from, :to, :partialFrom, :partialTo)

    one_second_more = days(Time.utc(2014, 6, 1, 7), Time.utc(2014, 6, 2, 7, 0, 1), la)
    assert_equal [ "2014-06-01", "2014-06-02", false, true ], one_second_more.values_at(:from, :to, :partialFrom, :partialTo)

    starts_at_midnight_utc = days(Time.utc(2014, 6, 2), Time.utc(2014, 6, 2, 7), la) # 17:00 to midnight local
    assert_equal [ "2014-06-01", "2014-06-01", true, false ], starts_at_midnight_utc.values_at(:from, :to, :partialFrom, :partialTo)

    utc = days(Time.utc(2014, 6, 1), Time.utc(2014, 7, 1), "UTC")
    assert_equal [ "2014-06-01", "2014-06-30", false, false ], utc.values_at(:from, :to, :partialFrom, :partialTo)
  end

  test "daylight saving changes: 23- and 25-hour days are whole days, and a skipped midnight still starts the day" do
    la = "America/Los_Angeles"
    spring = days(Time.utc(2014, 3, 9, 8), Time.utc(2014, 3, 10, 7), la) # 23 hours
    assert_equal [ "2014-03-09", "2014-03-09", false, false ], spring.values_at(:from, :to, :partialFrom, :partialTo)
    autumn = days(Time.utc(2014, 11, 2, 7), Time.utc(2014, 11, 3, 8), la) # 25 hours
    assert_equal [ "2014-11-02", "2014-11-02", false, false ], autumn.values_at(:from, :to, :partialFrom, :partialTo)
    an_hour_short = days(Time.utc(2014, 11, 2, 7), Time.utc(2014, 11, 3, 7), la)
    assert_equal [ "2014-11-02", "2014-11-02", false, true ], an_hour_short.values_at(:from, :to, :partialFrom, :partialTo)

    # Havana, 9 March 2014: clocks jump from 00:00 to 01:00, so the day starts at 01:00 (05:00 UTC).
    havana = days(Time.utc(2014, 3, 8, 5), Time.utc(2014, 3, 9, 5), "America/Havana")
    assert_equal [ "2014-03-08", "2014-03-08", false, false ], havana.values_at(:from, :to, :partialFrom, :partialTo)
    london = days(Time.utc(2014, 3, 1), Time.utc(2014, 4, 1), "Europe/London") # BST from 30 March
    assert_equal [ "2014-03-01", "2014-04-01", false, true ], london.values_at(:from, :to, :partialFrom, :partialTo),
                 "the first hour of 1 April local is still in the UTC month"
  end

  test "Overview coverage for a Pacific user: a missing UTC month seen through local months and custom ranges" do
    user = history_user
    user.update!(reporting_timezone: "America/Los_Angeles")
    committed(user, Time.utc(2014, 1, 1), Time.utc(2014, 6, 1))
    committed(user, Time.utc(2014, 7, 1), Time.utc(2015, 1, 1))

    june = overview(user, "month:2014-06")[:coverage] # local June starts 07:00 UTC on 1 June
    assert_equal "partial", june[:status], "the last seven hours of local June are in the imported UTC July"
    assert_equal [ [ "2014-06-01", "2014-06-30", false, true, "2014-07-01T00:00:00Z" ] ],
                 june[:missing].map { |m| m.values_at(:from, :to, :partialFrom, :partialTo, :endsAt) }

    may = overview(user, "month:2014-05")[:coverage]
    assert_equal [ [ "2014-05-31", "2014-05-31", true, false ] ], may[:missing].map { |m| m.values_at(:from, :to, :partialFrom, :partialTo) },
                 "only from 17:00 on 31 May, local"
    assert_equal({ status: "complete", missing: [] }, overview(user, "month:2014-07")[:coverage])
    assert_equal({ status: "complete", missing: [] }, overview(user, "custom:2014-07-01..2014-07-31")[:coverage])

    edge = overview(user, "custom:2014-06-30..2014-07-01")[:coverage]
    assert_equal "partial", edge[:status]
    assert_equal [ [ "2014-06-30", "2014-06-30", false, true ] ], edge[:missing].map { |m| m.values_at(:from, :to, :partialFrom, :partialTo) },
                 "1 July local is complete and never listed"
    assert_equal({ status: "complete", missing: [] }, overview(user, "custom:2014-07-01..2014-07-01")[:coverage])
  end

  test "coverage around a daylight saving change, in Pacific time" do
    user = history_user
    user.update!(reporting_timezone: "America/Los_Angeles")
    committed(user, Time.utc(2014, 1, 1), Time.utc(2014, 11, 1))
    committed(user, Time.utc(2014, 11, 3, 8), Time.utc(2015, 1, 1)) # from midnight PST on 3 November

    # Missing: 1 November 00:00 UTC (31 October 17:00 PDT) to 3 November 00:00 PST, across the change.
    nov = overview(user, "month:2014-11")[:coverage]
    assert_equal [ [ "2014-11-01", "2014-11-02", false, false ] ], nov[:missing].map { |m| m.values_at(:from, :to, :partialFrom, :partialTo) }
    assert_equal({ status: "complete", missing: [] }, overview(user, "day:2014-11-03")[:coverage])
    assert_equal "none", overview(user, "day:2014-11-02")[:coverage][:status], "a 25-hour day, all of it missing"
  end
end
