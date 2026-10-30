module HistoryImport
  # Recovery after crashes, restarts and stopped windows (docs/milestone-2-plan.md §7.3). Every
  # operation is safe to repeat and to run beside live workers: each window or run is changed with
  # a conditional UPDATE or under its row lock, and only when no live lease or job owns it.
  #
  # Never deleted: committed history, review records, catalogue rows, fetch records.
  class Recovery
    # A working run with no step for this long has lost its job chain (a crash between steps, a
    # job that failed for good). Longer than any step plus queueing delay.
    STALL_AFTER = 20.minutes
    # Restarts without progress before the run stops for a person.
    MAX_STALL_KICKS = 5

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    # The scheduled watchdog (ImportWatchdogJob).
    def run!
      result = { leases: recover_expired_leases!, staging: StagingCleaner.new(clock: @clock).call.to_h }
      result[:restarted] = HistoryImport.enabled? ? restart_stalled_runs! : 0 # never schedules while storage is off
      result
    end

    # Windows whose worker died and whose lease has expired go back to where a new worker starts:
    # `fetching`/`validating` to `pending` (the partial fetch is discarded by StagingCleaner),
    # `committing` to `validated` (the commit rolled back; staging is intact).
    def recover_expired_leases!
      count = 0
      ImportWindow.where(state: %w[fetching validating committing]).where(lease_expires_at: ...now).find_each do |window|
        count += ImportWindow.where(id: window.id, state: window.state, claim_token: window.claim_token).where(lease_expires_at: ...now)
                             .update_all(state: window.state == "committing" ? "validated" : "pending",
                                         claim_token: nil, lease_expires_at: nil, updated_at: now)
      end
      count
    end

    # Restarts working runs whose chain went quiet. A run restarted MAX_STALL_KICKS times without
    # progress stops as `failed` instead of being restarted forever.
    def restart_stalled_runs!
      quiet = now - STALL_AFTER
      stalled = ImportRun.working
                         .where("COALESCE(last_scheduled_at, created_at) < ?", quiet)
                         .where("last_activity_at IS NULL OR last_activity_at < ?", quiet)
                         .where("next_step_at IS NULL OR next_step_at < ?", quiet)
      stalled.find_each.count do |run|
        if run.stall_kicks >= MAX_STALL_KICKS
          ImportRun.where(id: run.id, job_token: run.job_token)
                   .update_all(state: "failed", job_token: nil, finished_at: now, updated_at: now,
                               last_error: "stalled: restarted #{run.stall_kicks} times without progress")
          next false
        end

        ImportRun.where(id: run.id, job_token: run.job_token).update_all("stall_kicks = stall_kicks + 1")
        Orchestrator.new(clock: @clock).schedule!(run, rotate_from: run.job_token)
      end
    end

    # A person retries a window that stopped (`failed` with no retry left) or went to review. It is
    # fetched again from scratch with fresh attempt counters and a fresh lifetime request budget;
    # the requests already made stay counted in http_requests_used. Committed windows never change.
    def retry_window!(window)
      HistoryImport.ensure_enabled!
      retried = ImportWindow.transaction do
        w = ImportWindow.lock.find(window.id)
        next false unless w.state == "needs_review" || w.gave_up?

        ImportWindowRow.where(import_window_fetch_id: w.fetches.select(:id)).delete_all
        w.update!(state: "pending", attempts: 0, commit_attempts: 0, retry_at: nil, validated_at: nil, fetched_count: nil,
                  expected_total: nil, http_requests_baseline: w.http_requests_used, claim_token: nil, lease_expires_at: nil,
                  last_error_message: "retried by hand (was: #{w.last_error_message.to_s.truncate(150)})")
        true
      end
      resume_waiting_run(window.user_id) if retried
      retried
    end

    # Retries every stopped or reviewed window of the user's import.
    def retry_all!(user)
      ImportWindow.live.where(user: user).where(state: %w[failed needs_review]).find_each.count do |w|
        (w.state == "needs_review" || w.gave_up?) && retry_window!(w)
      end
    end

    private

    def now = @clock.call

    def resume_waiting_run(user_id)
      run = ImportRun.find_by(user_id: user_id, state: "needs_review")
      Orchestrator.new(clock: @clock).resume!(run) if run
    end
  end
end
