module HistoryImport
  # Runs a user's historical import as a chain of short jobs (docs/milestone-2-plan.md §7). Each
  # job does one step and enqueues the next:
  #
  # - `planning`: verify the account with Last.fm (§5.1), plan the monthly windows, start running.
  # - `running`: take the next window due (newest first), validate it if needed, then commit it.
  #   Afterwards: enqueue the next step, wait for the earliest scheduled retry, finish the run, or
  #   hand it to a person (`needs_review`) when only stopped windows remain.
  #
  # One window's failure never stops the others. Steps are bounded, so a job never runs for long:
  # at most one window (up to 4 complete reads of at most 20 pages).
  #
  # Safety:
  # - Only the job carrying the run's current `job_token` acts, and it swaps the token for a new
  #   one as it starts (one conditional UPDATE), so of two deliveries of the same job only one
  #   proceeds. Pause, cancel and watchdog restarts replace the token too, so stale jobs stop at
  #   once. The step's token is also its lease token on the window it works on.
  # - A step that dies leaves the run with a token no job holds. If Solid Queue redelivers the job
  #   (it releases unfinished jobs on a graceful shutdown), the redelivered job may take over: its
  #   token is recorded as the one that started the step (`step_from_token`). It does so only once
  #   the step is provably dead, with no live window lease and no activity for a lease period;
  #   until then it re-enqueues itself for when the lease runs out. A crash without redelivery is
  #   left to the watchdog (Recovery), which restarts quiet runs.
  # - Last.fm requests happen outside transactions (the validator's rule). State changes here are
  #   single conditional UPDATEs.
  # - History storage must be enabled to enqueue and to run each step; turning it off stops the
  #   chain before anything else is written.
  class Orchestrator
    # Last.fm errors that stop the whole run: retrying any window would fail the same way.
    STOP_ERRORS = {
      9 => "Last.fm rejected the stored session. Sign in with Last.fm again to resume the import.",
      10 => "Last.fm rejected the API key. Check LASTFM_API_KEY, then resume the import.",
      26 => "Last.fm suspended the API key. Resume the import once it is restored."
    }.freeze

    # A run stopped for a reason a person must deal with (account changed, access revoked).
    class Stop < StandardError; end

    def initialize(clock: -> { Time.current }, client: nil)
      @clock = clock
      @client = client
    end

    # Starts an import for the user, or returns the active one. Safe to call repeatedly.
    def start!(user)
      HistoryImport.ensure_enabled!
      run = ImportRun.active.find_by(user: user) || create_run(user)
      schedule!(run, rotate_from: run.job_token) if run.working? && run.last_scheduled_at.nil?
      run
    end

    # Stops scheduling new steps. A step already running finishes its window (commits are atomic).
    def pause!(run)
      transition!(run, from: %w[planning running needs_review], to: "paused", paused_at: now)
    end

    # Resumes a paused run, or a run waiting for review once its windows were retried. The account
    # is verified again first.
    def resume!(run)
      HistoryImport.ensure_enabled!
      return run.reload unless transition!(run, from: %w[paused needs_review], to: "planning", paused_at: nil, stall_kicks: 0)

      schedule!(run.reload, rotate_from: nil)
      run.reload
    end

    # Prevents any further work. Committed history stays; uncommitted windows stay as they are and
    # a later run picks them up.
    def cancel!(run)
      transition!(run, from: ImportRun::ACTIVE_STATES, to: "cancelled", cancelled_at: now, finished_at: now)
      LastfmConnection.where(user_id: run.user_id, history_state: "importing").update_all(history_state: "not_started", updated_at: now)
    end

    # One step of the chain. Returns what happened, for tests and logs.
    def step!(run_id, token)
      HistoryImport.ensure_enabled!
      run = ImportRun.find_by(id: run_id)
      return :gone unless run # the account was deleted

      step_token = SecureRandom.uuid
      taken = ImportRun.where(id: run.id, job_token: token, state: ImportRun::WORKING_STATES)
                       .update_all(job_token: step_token, step_from_token: token, next_step_at: nil, last_activity_at: now, updated_at: now)
      if taken.zero?
        outcome = take_over_interrupted_step(run, token, step_token)
        return outcome unless outcome == :taken_over
      end

      run.reload
      identity = active_identity(run.user)
      run.state == "planning" ? plan(run, identity) : work(run, identity, step_token)
    rescue Stop => e
      stop!(run, e.message)
      :stopped
    rescue ActiveRecord::RecordNotFound
      :gone # the account was deleted mid-step; its windows went with it
    end

    # Enqueues the next step, replacing the token so only that job may act. `rotate_from` is the
    # token the caller holds; nil means take over regardless (resume, watchdog restart).
    def schedule!(run, rotate_from:, wait: nil)
      HistoryImport.ensure_enabled!
      new_token = SecureRandom.uuid
      at = wait && now + wait
      scope = ImportRun.where(id: run.id, state: ImportRun::WORKING_STATES)
      scope = rotate_from ? scope.where(job_token: rotate_from) : scope
      return false unless scope.update_all(job_token: new_token, step_from_token: nil, last_scheduled_at: now, next_step_at: at, updated_at: now) == 1

      job = ImportRunJob.set(wait: wait || 0)
      job.perform_later(run.id, new_token)
      true
    end

    private

    def now = @clock.call

    # This job started the run's current step, and is running again: Solid Queue redelivered it
    # after its process stopped, or it is a duplicate. Take the step over only if it is dead.
    def take_over_interrupted_step(run, token, step_token)
      run.reload # the step that just won the token may have started after `run` was read
      return :superseded unless run.step_from_token == token && run.working?

      live_until = [ ImportWindow.where(claim_token: run.job_token).maximum(:lease_expires_at),
                     run.last_activity_at && run.last_activity_at + ImportWindow::LEASE ].compact.max
      if live_until && live_until > now
        ImportRunJob.set(wait: (live_until - now) + 1.second).perform_later(run.id, token)
        return :deferred
      end

      taken = ImportRun.where(id: run.id, job_token: run.job_token, step_from_token: token, state: ImportRun::WORKING_STATES)
                       .update_all(job_token: step_token, next_step_at: nil, last_activity_at: now, updated_at: now)
      taken == 1 ? :taken_over : :superseded
    end

    def client = @client ||= Lastfm::Config.client(**Lastfm::Client::BACKGROUND_OPTIONS)

    def create_run(user)
      ImportRun.create!(user: user, kind: "full", state: "planning", started_at: now)
    rescue ActiveRecord::RecordNotUnique
      ImportRun.active.find_by!(user: user) # another request started it at the same moment
    end

    def transition!(run, from:, to:, **changes)
      ImportRun.where(id: run.id, state: from).update_all(state: to, job_token: nil, step_from_token: nil, updated_at: now, **changes) == 1
    end

    # The account may still be imported: linked, not revoked, holding a session, and allowed.
    def active_identity(user)
      identity = user.lastfm_identity
      raise Stop, "Last.fm access was revoked. Sign in with Last.fm again to resume the import." unless identity&.revoked_at.nil? && identity&.session_key
      raise Stop, "This Last.fm account is no longer allowed (LASTFM_ALLOWED_USERNAME)." unless Lastfm::AccountPolicy.allowed?(identity.username)

      identity
    end

    # §5.1: the session must still act for the same account before anything is fetched.
    def plan(run, identity)
      info = begin
        client.user_info(session_key: identity.session_key)
      rescue Lastfm::Error => e
        raise Stop, STOP_ERRORS[e.code] if STOP_ERRORS.key?(e.code)
        raise Stop, "Account check failed: #{e.message}" unless e.retryable?

        return retry_planning(run, e)
      end
      unless Lastfm::AccountPolicy.normalize(info[:username]) == identity.uid
        raise Stop, "Your Last.fm username changed. Relink the account (server/README.md) to resume the import."
      end
      raise Stop, "The Last.fm account's registration time doesn't match (identity_changed)." unless info[:registered_at] && info[:registered_at] == identity.registered_at

      return start_reconciling(run) if run.kind == "reconcile"

      history_from = run.history_from || Time.utc(info[:registered_at].year, info[:registered_at].month, 1)
      # A run that follows a cancelled one keeps the cutoff its windows were planned with: a later
      # cutoff would leave a gap the monthly planner can't fill (it skips the overlapping current
      # month). Plays after the cutoff are for sync (Stage 2.7).
      cutoff = run.cutoff_at || ImportWindow.live.where(user_id: run.user_id).maximum(:window_to) || now.utc.beginning_of_minute
      WindowPlanner.plan!(user: run.user, from: history_from, cutoff: cutoff, run: run)
      # Windows left by an earlier, cancelled run join this one.
      ImportWindow.live.where(user_id: run.user_id).where.not(state: "committed").where.not(import_run_id: run.id).update_all(import_run_id: run.id)
      ImportRun.where(id: run.id, job_token: run.job_token, state: "planning")
               .update_all(state: "running", history_from: history_from, cutoff_at: cutoff, reported_playcount: info[:playcount],
                           last_activity_at: now, updated_at: now)
      LastfmConnection.where(user_id: run.user_id).update_all(history_state: "importing", last_error: nil, updated_at: now)
      schedule!(run, rotate_from: run.job_token)
      :planned
    end

    # A recheck run (HistoryImport::Recheck): its windows exist already; nothing to plan.
    def start_reconciling(run)
      ImportRun.where(id: run.id, job_token: run.job_token, state: "planning")
               .update_all(state: "running", last_activity_at: now, updated_at: now)
      schedule!(run, rotate_from: run.job_token)
      :planned
    end

    # A transient failure while checking the account: try again later, a bounded number of times.
    def retry_planning(run, error)
      raise Stop, "Account check kept failing: #{error.message}" if run.stall_kicks + 1 >= Recovery::MAX_STALL_KICKS

      ImportRun.where(id: run.id, job_token: run.job_token).update_all("stall_kicks = stall_kicks + 1")
      schedule!(run, rotate_from: run.job_token, wait: ImportWindow.retry_delay(run.stall_kicks + 1, retry_after: error.retry_after))
      :retrying
    end

    def work(run, identity, token)
      window = next_window(run, token)
      return finish_or_wait(run, token) unless window

      ImportRun.where(id: run.id, job_token: token).update_all(current_window_id: window.id, last_activity_at: now, updated_at: now)
      if %w[pending failed fetching validating].include?(window.state)
        result = WindowValidator.new(window: window, client: client, username: identity.username,
                                     session_key: identity.session_key, token: token, clock: @clock).call
        stop_error = STOP_ERRORS[window.reload.last_lastfm_error]
        raise Stop, stop_error if result.status == :failed && stop_error
      end
      # Paused or cancelled while validating: don't commit; the window stays validated.
      return :superseded unless ImportRun.where(id: run.id, job_token: token).exists?

      if %w[validated committing].include?(window.reload.state) && (window.retry_at.nil? || window.retry_at <= now)
        result = WindowCommitter.new(window: window, token: token, clock: @clock).call
        committed(run, token) if result.status == :committed
      end
      ImportRun.where(id: run.id, job_token: token).update_all(stall_kicks: 0, last_activity_at: now, updated_at: now)
      schedule!(run, rotate_from: token)
      result&.status || :skipped
    end

    def committed(run, token)
      ImportRun.where(id: run.id, job_token: token).update_all(last_committed_at: now, updated_at: now)
      CatalogueMatchJob.perform_later
    end

    # The window this step should work on: one ready to commit first, then the newest one due.
    # Windows another live worker holds are skipped; this chain's own (same token) are resumed.
    def next_window(run, token)
      due = run_windows(run).where(<<~SQL, now: now, token: token)
        state = 'pending'
        OR (state = 'failed' AND retry_at <= :now)
        OR (state = 'validated' AND (retry_at IS NULL OR retry_at <= :now))
        OR (state IN ('fetching', 'validating', 'committing') AND (claim_token IS NULL OR claim_token = :token OR lease_expires_at < :now))
      SQL
      due.order(Arel.sql("CASE WHEN state IN ('validated', 'committing') THEN 0 ELSE 1 END"), window_from: :desc).first
    end

    def finish_or_wait(run, token)
      remaining = run_windows(run).where.not(state: "committed")
      if remaining.none?
        complete!(run, token)
        return :completed
      end

      waiting_until = [ remaining.where(state: %w[failed validated]).minimum(:retry_at),
                        remaining.where(state: %w[fetching validating committing]).minimum(:lease_expires_at) ].compact.min
      if waiting_until
        schedule!(run, rotate_from: token, wait: [ waiting_until - now, 1.second ].max)
        return :waiting
      end

      # Only stopped (`failed` with no retry) or `needs_review` windows remain.
      ImportRun.where(id: run.id, job_token: token).update_all(state: "needs_review", job_token: nil, current_window_id: nil,
                                                               last_error: "#{remaining.count} periods need attention", updated_at: now)
      :needs_review
    end

    # A run works only on its own windows: an import on the months it planned or adopted, a
    # recheck on the months it was asked to check. (Split halves inherit their parent's run.)
    def run_windows(run) = ImportWindow.live.where(user_id: run.user_id, import_run_id: run.id)

    def complete!(run, token)
      done = ImportRun.where(id: run.id, job_token: token)
                      .update_all(state: "completed", job_token: nil, current_window_id: nil, finished_at: now, updated_at: now)
      return unless done == 1 && run.kind == "full"

      LastfmConnection.where(user_id: run.user_id).update_all(history_state: "imported", last_error: nil, updated_at: now)
    end

    def stop!(run, message)
      ImportRun.where(id: run.id).update_all(state: "failed", job_token: nil, last_error: message, finished_at: now, updated_at: now)
      LastfmConnection.where(user_id: run.user_id).update_all(history_state: "failed", last_error: message, updated_at: now)
    end
  end
end
