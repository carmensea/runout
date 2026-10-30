module HistoryImport
  # Creates the monthly windows for a user's history, from the Last.fm registration month up to
  # `cutoff`. Idempotent: ranges that overlap an existing live window are skipped, so re-planning
  # never duplicates or conflicts. Sync extends the partial current month (SyncPlanner).
  module WindowPlanner
    module_function

    def plan!(user:, from:, cutoff:, run: nil)
      HistoryImport.ensure_enabled!

      MonthlyWindows.ranges(from: from, cutoff: cutoff).filter_map do |range|
        next if ImportWindow.live.where(user: user).where("window_from < ? AND window_to > ?", range.end, range.begin).exists?

        ImportWindow.create!(user: user, import_run: run, window_from: range.begin, window_to: range.end, state: "pending")
      end
    end
  end
end
