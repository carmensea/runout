module Listening
  # What connected sources confirm (docs/spotify-plan.md §10): for each source, from the oldest play
  # its first successful poll returned to its latest successful poll, minus every unresolved gap.
  # Between two successful polls with no gap, the source returned everything it had, so nothing it
  # recorded is missing there. Before the first poll, after the last one, and inside a gap, nothing
  # is claimed.
  #
  # "Complete" means complete for the sources Runout records: plays on services Runout doesn't
  # read can't be known.
  module Coverage
    module_function

    def ranges(user)
      sources = ListeningSource.where(user: user).where.not(covered_from: nil).where.not(last_success_at: nil).to_a
      return [] if sources.empty?

      gaps = ListeningGap.open.where(listening_source_id: sources.map(&:id)).group_by(&:listening_source_id)
      sources.flat_map do |source|
        cut(source.covered_from...source.last_success_at, gaps.fetch(source.id, []).map { |g| g.gap_from...g.gap_to })
      end
    end

    # Merges half-open ranges, sorted.
    def merge(ranges)
      ranges.sort_by(&:begin).each_with_object([]) do |range, merged|
        if merged.any? && range.begin <= merged.last.end
          last = merged.pop
          merged << (last.begin...[ last.end, range.end ].max)
        else
          merged << range
        end
      end
    end

    def cut(range, holes)
      holes.sort_by(&:begin).each_with_object([ range ]) do |hole, pieces|
        last = pieces.pop
        pieces << (last.begin...[ hole.begin, last.end ].min) if hole.begin > last.begin
        pieces << ([ hole.end, last.begin ].max...last.end) if hole.end < last.end
      end.select { |r| r.begin < r.end }
    end
  end
end
