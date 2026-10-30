# Which parts of a user's history are fully imported: the union of windows committed at least once
# (a later reconciliation of a month, or its open review items, never take its coverage away), as
# half-open [from, to) ranges with adjacent windows merged. Anything outside these ranges is not
# known to be complete, so charts must not present it as complete.
module ImportCoverage
  module_function

  def ranges(user)
    windows = ImportWindow.live.imported.where(user: user).order(:window_from).pluck(:window_from, :window_to)
    windows.each_with_object([]) do |(from, to), merged|
      if merged.any? && from <= merged.last.end
        last = merged.pop
        merged << (last.begin...[ last.end, to ].max)
      else
        merged << (from...to)
      end
    end
  end

  # Whether every moment in [from, to) lies inside committed windows.
  def complete?(user, from, to)
    status_for(user, from, to) == :complete
  end

  # :complete when all of [from, to) is committed, :partial when only some of it is, :missing
  # when none of it is. Validated windows that aren't committed yet count as missing.
  def status_for(user, from, to)
    covered = ranges(user).sum do |range|
      overlap = [ range.end, to ].min - [ range.begin, from ].max
      overlap.positive? ? overlap : 0
    end
    if covered >= to - from then :complete
    elsif covered.positive? then :partial
    else :missing
    end
  end
end
