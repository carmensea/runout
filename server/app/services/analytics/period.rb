module Analytics
  # A reporting period, as the frontend serialises it (src/lib/period.ts): `all`, `l12`,
  # `year:2014`, `month:2014-03`, `week:2014-W11`, `day:2014-03-15`,
  # `custom:2014-03-01..2014-05-31`. Dates are calendar dates in the user's reporting timezone,
  # inclusive at both ends, exactly as `periodRange` resolves them.
  #
  # `utc_range` turns those dates into the half-open UTC interval of instants the plays are
  # filtered by: from local midnight at the start to local midnight after the end. Daylight saving
  # time is handled by the timezone database (a day may last 23 or 25 hours); a local midnight
  # that doesn't exist resolves to the first instant after the gap.
  Period = Data.define(:kind, :from, :to, :serialized) do
    def self.parse(raw, time_zone:, today: nil)
      tz = Period.zone(time_zone)
      today ||= Time.current.in_time_zone(tz).to_date
      kind, value = raw.to_s.split(":", 2)
      case kind
      when "all" then new(kind: "all", from: nil, to: nil, serialized: "all")
      when "l12"
        from = (today << 11).beginning_of_month
        new(kind: "l12", from: from, to: today, serialized: "l12")
      when "year"
        raise ArgumentError, "bad year" unless value.to_s.match?(/\A\d{4}\z/)

        year = value.to_i
        new(kind: "year", from: Date.new(year, 1, 1), to: Date.new(year, 12, 31), serialized: raw)
      when "month"
        m = /\A(\d{4})-(\d{2})\z/.match(value.to_s) or raise ArgumentError, "bad month"
        start = Date.new(m[1].to_i, m[2].to_i, 1)
        new(kind: "month", from: start, to: start.end_of_month, serialized: raw)
      when "week"
        m = /\A(\d{4})-W(\d{2})\z/.match(value.to_s) or raise ArgumentError, "bad week"
        start = Date.commercial(m[1].to_i, m[2].to_i, 1)
        new(kind: "week", from: start, to: start + 6, serialized: raw)
      when "day"
        date = Date.iso8601(value.to_s)
        new(kind: "day", from: date, to: date, serialized: raw)
      when "custom"
        from, to = value.to_s.split("..", 2).map { |d| Date.iso8601(d.to_s) }
        raise ArgumentError, "bad custom range" unless from && to && from <= to

        new(kind: "custom", from: from, to: to, serialized: raw)
      else
        raise ArgumentError, "unknown period"
      end
    rescue Date::Error
      raise ArgumentError, "bad date"
    end

    def self.zone(name) = ActiveSupport::TimeZone[name.to_s] || ActiveSupport::TimeZone["UTC"]

    # A UTC interval [begin, end) as the local calendar days it touches, inclusive. The end is
    # exclusive: an interval ending at local midnight doesn't touch the day after. `partialFrom`
    # and `partialTo` say the first or last day is only partly inside it. A day starts at local
    # midnight, or the first moment after it where daylight saving time skips midnight.
    def self.local_days(range, time_zone)
      tz = zone(time_zone)
      start = range.begin.in_time_zone(tz)
      finish = range.end.in_time_zone(tz)
      first = start.to_date
      last = finish.to_date
      last -= 1 if finish <= day_start(tz, last)
      { from: first.iso8601, to: last.iso8601, startsAt: start.utc.iso8601, endsAt: finish.utc.iso8601,
        partialFrom: start > day_start(tz, first), partialTo: finish < day_start(tz, last + 1) }
    end

    def self.day_start(tz, date) = tz.local(date.year, date.month, date.day)

    def all? = kind == "all"

    # [from, to) in UTC; nil ends for `all`.
    def utc_range(time_zone)
      tz = Period.zone(time_zone)
      return nil..nil if all?

      tz.local(from.year, from.month, from.day).utc...tz.local((to + 1).year, (to + 1).month, (to + 1).day).utc
    end
  end
end
