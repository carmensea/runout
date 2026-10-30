module HistoryImport
  # Arms the windows a synchronisation run checks (docs/milestone-2-plan.md §5.2). Runs in the
  # run's planning step, after the account check, in one transaction under the per-user lock.
  # Makes no Last.fm requests.
  #
  # The frontier is where the user's windows end: the full import's cutoff at first, later the
  # point the last sync reached. A run checks [since, target):
  # - Committed windows overlapping [since, frontier) are checked again over that overlap and
  #   reconciled (Stage 2.4b): new plays are added, missing ones start the removal process.
  # - Past the frontier, the last window grows within its own month: its check range ends past
  #   window_to, and the window reaches that end only when the check commits. Later months get new
  #   windows, split at UTC month boundaries; a month with no plays is committed with 0.
  # Windows never overlap, and every range is half-open [from, to), like Last.fm's `from`
  # (inclusive) and `to` (exclusive), so consecutive ranges neither miss nor repeat a second.
  #
  # Stopped windows:
  # - A window waiting for review (`needs_review`) is never touched. If it is the last window,
  #   nothing is planned past it: coverage must not jump over a period nobody has resolved.
  # - A window that gave up (`failed`, no retry left) is tried again with fresh counters, at most
  #   once per `rearm_after`, so a persistent failure costs a bounded number of requests.
  module SyncPlanner
    Plan = Data.define(:armed, :created, :blocked_by)

    module_function

    def plan!(run, since:, target:, now:, rearm_after: HistoryImport::Sync.config[:rearm_after])
      HistoryImport.ensure_enabled!
      ImportWindow.uncached do
        ImportWindow.transaction do
          ImportWindow.connection.execute(ImportWindow.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "history:#{run.user_id}" ]))
          windows = ImportWindow.live.where(user_id: run.user_id).order(:window_from).lock.to_a
          return Plan.new(armed: [], created: [], blocked_by: nil) if windows.empty?

          last = windows.max_by(&:window_to)
          frontier = last.window_to
          armed = []
          windows.each do |w|
            if w.state == "committed"
              range_end = w.equal?(last) ? extended_end(w, target) : w.window_to
              from = [ w.window_from, since ].max
              next unless from < range_end && (w.window_to > since || range_end > w.window_to)

              armed << arm!(w, run, from: from, to: range_end, now: now)
            elsif adoptable?(w, now, rearm_after)
              armed << adopt!(w, run, now: now)
            end
          end

          blocked = last.state == "needs_review" || (last.state != "committed" && !armed.include?(last.id))
          created = []
          unless blocked
            # Past the last window, or past the extension it is still waiting to commit: when that
            # commits, the window grows to its check_to, which must not reach into a new window.
            start = last.state == "committed" ? extended_end(last, target) : [ frontier, last.check_to ].compact.max
            created = MonthlyWindows.split(from: [ start, frontier ].max, to: target).map do |range|
              ImportWindow.create!(user_id: run.user_id, import_run: run, window_from: range.begin, window_to: range.end, state: "pending")
            end
          end
          Plan.new(armed: armed.compact, created: created.map(&:id), blocked_by: (last.id if blocked))
        end
      end
    end

    # The last window may grow up to the end of its own month, never into the next one.
    def extended_end(window, target)
      [ [ MonthlyWindows.month_end(window.window_from), target ].min, window.window_to ].max
    end

    # Windows left over by an earlier sync run that ended: new periods it never committed, or
    # periods whose check gave up (tried again once `rearm_after` has passed).
    def adoptable?(window, now, rearm_after)
      case window.state
      when "needs_review" then false
      when "failed" then window.retry_at.present? || window.updated_at < now - rearm_after
      else true # pending, or a crashed worker's fetching/validating/validated/committing
      end
    end

    # A conditional UPDATE: only a window still committed is armed.
    def arm!(window, run, from:, to:, now:)
      updated = ImportWindow.where(id: window.id, state: "committed").update_all(
        [ "state = 'pending', import_run_id = :run, check_from = :from, check_to = :to, attempts = 0, commit_attempts = 0, " \
          "retry_at = NULL, validated_at = NULL, fetched_count = NULL, expected_total = NULL, last_error_message = NULL, " \
          "http_requests_baseline = http_requests_used, updated_at = :now",
          { run: run.id, from: (from unless from == window.window_from), to: (to unless to == window.window_to), now: now } ]
      )
      window.id if updated == 1
    end

    def adopt!(window, run, now:)
      changes = { import_run_id: run.id, updated_at: now }
      if window.state == "failed" && window.retry_at.nil? # gave up: fresh counters, like a manual retry
        changes.merge!(state: "pending", attempts: 0, commit_attempts: 0, last_error_message: nil)
        ImportWindow.where(id: window.id).update_all([ "http_requests_baseline = http_requests_used" ])
      end
      ImportWindow.where(id: window.id, state: window.state).update_all(changes) == 1 ? window.id : nil
    end
  end
end
