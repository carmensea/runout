module HistoryImport
  # Asks for committed months to be checked against Last.fm again and reconciled
  # (HistoryImport::Reconciler). The months keep their coverage throughout: they go back through
  # the same fetch, validation and commit steps on their existing windows, so no new or
  # overlapping windows are created. Runs as an ImportRun of kind `reconcile`; at most one run per
  # user is active, so a recheck waits for an import to finish. (Scheduling rechecks is Stage 2.7.)
  module Recheck
    class Busy < StandardError; end

    module_function

    # Returns the run, or nil if no committed month falls in the range.
    def request!(user, from: nil, to: nil, clock: -> { Time.current })
      HistoryImport.ensure_enabled!
      raise Busy, "an import or check is already active for this account" if ImportRun.active.exists?(user: user)

      now = clock.call
      windows = ImportWindow.live.imported.committed.where(user: user)
      windows = windows.where("window_to > ?", from) if from
      windows = windows.where("window_from < ?", to) if to
      return nil unless windows.exists?

      run = ImportRun.transaction do
        r = ImportRun.create!(user: user, kind: "reconcile", state: "planning", started_at: now,
                              history_from: windows.minimum(:window_from), cutoff_at: windows.maximum(:window_to))
        # Fresh attempt counters and lifetime request budget for the check; requests stay counted.
        windows.update_all([ "state = 'pending', import_run_id = ?, attempts = 0, commit_attempts = 0, retry_at = NULL, " \
                             "validated_at = NULL, fetched_count = NULL, expected_total = NULL, last_error_message = NULL, " \
                             "http_requests_baseline = http_requests_used, updated_at = ?", r.id, now ])
        r
      end
      Orchestrator.new(clock: clock).schedule!(run, rotate_from: nil)
      run
    rescue ActiveRecord::RecordNotUnique
      raise Busy, "an import or check is already active for this account"
    end
  end
end
