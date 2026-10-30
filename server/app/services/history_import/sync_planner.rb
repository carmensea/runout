module HistoryImport
  # Arms the windows a synchronisation run checks (docs/milestone-2-plan.md §5.2, §15.6). Runs in
  # the run's planning step, after the account check, in one transaction under the per-user lock.
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
  # A stopped period (waiting for review, or given up) never holds later listening back:
  # - Transient stops (ImportWindow#transient_stop?) are tried again with fresh counters, at most
  #   once per `rearm_after`, so a persistent failure costs a bounded number of requests.
  # - A period imported before keeps its plays and coverage. If its stopped check was also
  #   extending it, the extension is detached (its check range cut back to window_to) and the
  #   range is planned as an ordinary new window instead.
  # - A period never imported that stopped for an integrity reason is split in halves, down to
  #   WindowSplitter's minimum, to isolate the problem; what can't be imported stays a coverage
  #   gap (ImportCoverage, SyncHealth#missingPeriods), never reported as complete.
  # Integrity stops are never retried automatically: they wait for a person.
  module SyncPlanner
    Plan = Data.define(:armed, :created, :split, :detached)

    module_function

    def plan!(run, since:, target:, now:, rearm_after: HistoryImport::Sync.config[:rearm_after])
      HistoryImport.ensure_enabled!
      ImportWindow.uncached do
        ImportWindow.transaction do
          ImportWindow.connection.execute(ImportWindow.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "history:#{run.user_id}" ]))
          windows = ImportWindow.live.where(user_id: run.user_id).order(:window_from).lock.to_a
          return Plan.new(armed: [], created: [], split: [], detached: []) if windows.empty?

          last = windows.max_by(&:window_to)
          armed = []
          split = []
          detached = []
          reserved = [] # where each window's range, including a pending extension, ends
          windows.each do |w|
            if w.state == "committed"
              range_end = w.equal?(last) ? extended_end(w, target) : w.window_to
              from = [ w.window_from, since ].max
              armed << arm!(w, run, from: from, to: range_end, now: now) if from < range_end && (w.window_to > since || range_end > w.window_to)
              reserved << range_end
            elsif w.stopped?
              if w.transient_stop? && w.updated_at <= now - rearm_after
                armed << rearm!(w, run, now: now)
              elsif w.committed_at.nil? && WindowSplitter.splittable?(w)
                split.concat(split!(w, run, now: now))
              elsif w.committed_at && w.check_to && w.check_to > w.window_to
                detached << detach!(w, now: now)
                reserved << w.window_to
                next
              end
              reserved << [ w.window_to, w.check_to ].compact.max
            else
              armed << adopt!(w, run, now: now) # left by an earlier run: new periods, crashed workers
              reserved << [ w.window_to, w.check_to ].compact.max
            end
          end

          created = MonthlyWindows.split(from: reserved.max, to: target).map do |range|
            ImportWindow.create!(user_id: run.user_id, import_run: run, window_from: range.begin, window_to: range.end, state: "pending")
          end
          Plan.new(armed: armed.compact, created: created.map(&:id), split: split, detached: detached)
        end
      end
    end

    # The last window may grow up to the end of its own month, never into the next one.
    def extended_end(window, target)
      [ [ MonthlyWindows.month_end(window.window_from), target ].min, window.window_to ].max
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

    # A transient stop, due for another try: fresh counters and request budget, like a manual retry.
    # Staging is discarded (it is fetched again); fetch records stay for audit.
    def rearm!(window, run, now:)
      ImportWindowRow.where(import_window_fetch_id: window.fetches.select(:id)).delete_all
      window.update!(state: "pending", import_run_id: run.id, review_reason: nil, attempts: 0, commit_attempts: 0, retry_at: nil,
                     validated_at: nil, fetched_count: nil, expected_total: nil, http_requests_baseline: window.http_requests_used,
                     claim_token: nil, lease_expires_at: nil, updated_at: now,
                     last_error_message: "tried again automatically (was: #{window.last_error_message.to_s.truncate(150)})")
      window.id
    end

    def adopt!(window, run, now:)
      ImportWindow.where(id: window.id, state: window.state).update_all(import_run_id: run.id, updated_at: now) == 1 ? window.id : nil
    end

    # A never-imported period stopped for an integrity reason: two halves, imported separately, so
    # the problem is isolated to the smallest period that still holds it.
    def split!(window, run, now:)
      ImportWindowRow.where(import_window_fetch_id: window.fetches.select(:id)).delete_all
      children = WindowSplitter.split!(window)
      ImportWindow.where(id: children.map(&:id)).update_all(import_run_id: run.id, updated_at: now)
      children.map(&:id)
    end

    # An imported period whose stopped check was also extending it: the extension leaves its check
    # (and is planned as a new window); the check keeps only the committed part, for a person.
    def detach!(window, now:)
      check_from = window.check_from if window.check_from && window.check_from < window.window_to
      window.update!(check_from: check_from, check_to: nil, updated_at: now)
      window.id
    end
  end
end
