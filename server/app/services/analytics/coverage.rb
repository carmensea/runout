module Analytics
  # Whether stored history covers a UTC interval (docs/milestone-3-plan.md §1, coverage): `complete`,
  # `partial` or `none`, with the missing ranges as local days (Period.local_days). Imported ranges
  # come from ImportCoverage and are read once per instance, so one view can ask about many
  # intervals (every day of a month, the same date in twenty years) at the cost of one query. The
  # part of an interval still in the future isn't missing.
  class Coverage
    def initialize(user, time_zone, now: Time.current)
      @ranges = ImportCoverage.ranges(user)
      @tz = time_zone
      @now = now
    end

    # `from...to` in UTC; nil ends mean the imported history's own extent.
    def for(from, to)
      return { status: "none", missing: [] } if @ranges.empty?

      from ||= @ranges.first.begin
      to = to ? [ to, @now ].min : @ranges.last.end
      return { status: "complete", missing: [] } if to <= from

      gaps = gaps(from, to)
      { status: status(gaps, to - from), missing: gaps.map { |g| Period.local_days(g, @tz) } }
    end

    # Just the status, without listing what is missing.
    def status_for(from, to) = self.for(from, to)[:status]

    private

    def gaps(from, to)
      edges = [ from, *@ranges.flat_map { |r| [ r.begin.clamp(from, to), r.end.clamp(from, to) ] }, to ]
      edges.each_slice(2).filter_map { |a, b| (a...b) if a < b }
    end

    def status(gaps, span)
      return "complete" if gaps.empty?

      gaps.sum { |g| g.end - g.begin } >= span ? "none" : "partial"
    end
  end
end
