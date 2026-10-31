module Analytics
  # Time Machine's map of the history (src/pages/time-machine): plays per local calendar day, month
  # and year, from Runout's own stored plays, under the Overview's rules (docs/milestone-3-plan.md
  # §1): removed plays don't count, days are local dates in the reporting timezone, and where the
  # history isn't imported is said, never shown as silence.
  class Calendar
    MAX_DAYS = 400 # a year (and a little) at a time

    def initialize(user:, now: Time.current)
      @user = user
      @tz = user.reporting_timezone.presence || "UTC"
      @now = now
    end

    # The whole history: its first and latest days with plays, plays per year and per month, and
    # which parts aren't imported. `lastDay` is the most recent local day with a play, which may be
    # long before today.
    def history
      months = rows(<<~SQL, user: @user.id, tz: @tz)
        SELECT to_char(lt, 'YYYY-MM'), count(*), to_char(min(lt), 'YYYY-MM-DD'), to_char(max(lt), 'YYYY-MM-DD')
          FROM (SELECT (played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz AS lt FROM scrobbles WHERE user_id = :user AND removed_at IS NULL) p
         GROUP BY 1 ORDER BY 1
      SQL
      years = months.group_by { |m, *| m[0, 4] }.map { |year, list| { key: year, scrobbles: list.sum { |_, n, *| n } } }
      { firstDay: months.first&.dig(2), lastDay: months.last&.dig(3), years: years,
        months: months.map { |m, n, *| { key: m, scrobbles: n } }, coverage: Coverage.new(@user, @tz, now: @now).for(nil, nil) }
    end

    # Plays per local day from `from` to `to`, inclusive local dates. Days without plays are left
    # out; `coverage` says which of them are known to be empty.
    def days(from, to)
      raise ArgumentError, "the range ends before it starts" if to < from
      raise ArgumentError, "at most #{MAX_DAYS} days at a time" if (to - from).to_i + 1 > MAX_DAYS

      range = Period.new(kind: "custom", from: from, to: to, serialized: "custom:#{from}..#{to}").utc_range(@tz)
      days = rows(<<~SQL, user: @user.id, tz: @tz, from: range.begin, to: range.end)
        SELECT to_char((played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM-DD'), count(*)
          FROM scrobbles WHERE user_id = :user AND removed_at IS NULL AND played_at >= :from AND played_at < :to
         GROUP BY 1 ORDER BY 1
      SQL
      { from: from.iso8601, to: to.iso8601, days: days.map { |d, n| { date: d, scrobbles: n } },
        coverage: Coverage.new(@user, @tz, now: @now).for(range.begin, range.end) }
    end

    private

    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
  end
end
