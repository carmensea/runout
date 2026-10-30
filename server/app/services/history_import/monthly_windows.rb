module HistoryImport
  # Calendar-month ranges in UTC, half-open [from, to), matching Last.fm's verified boundaries:
  # `from` inclusive, `to` exclusive (docs/lastfm-api-findings.md, A2). Months come from calendar
  # arithmetic, never fixed day counts, so February and leap years are exact. The last range is cut
  # at `cutoff` (usually the start of the import run), so the current month is partial.
  module MonthlyWindows
    module_function

    def ranges(from:, cutoff:)
      from = from.utc
      cutoff = cutoff.utc
      return [] unless from < cutoff

      start = Time.utc(from.year, from.month, 1)
      result = []
      while start < cutoff
        finish = next_month(start)
        result << (start...[ finish, cutoff ].min)
        start = finish
      end
      result
    end

    def next_month(time)
      time.month == 12 ? Time.utc(time.year + 1, 1, 1) : Time.utc(time.year, time.month + 1, 1)
    end
  end
end
