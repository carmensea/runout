# Which parts of a user's history are fully imported: the union of committed windows, as
# half-open [from, to) ranges with adjacent windows merged. Anything outside these ranges is not
# known to be complete, so charts must not present it as complete.
module ImportCoverage
  module_function

  def ranges(user)
    windows = ImportWindow.live.committed.where(user: user).order(:window_from).pluck(:window_from, :window_to)
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
    ranges(user).any? { |range| range.begin <= from && range.end >= to }
  end
end
