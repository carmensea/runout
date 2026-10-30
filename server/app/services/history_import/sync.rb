module HistoryImport
  # Ongoing synchronisation after the full import (docs/milestone-2-plan.md §5.2). Three kinds of
  # run, each an ImportRun processed by the same job chain, validator and reconciler as the import:
  #
  # - `sync` (every `sync_every`): recent plays. Checks from `lookback` before the frontier up to
  #   `settle` before now, so plays still being scrobbled are left for the next run, and plays
  #   that arrived late inside the lookback are still caught.
  # - `catch_up` (every `catch_up_every`): the last `catch_up_span`, for back-dated (offline)
  #   scrobbles. It also extends the frontier, like `sync`.
  # - `reconcile` (every `reconcile_every`): compares each committed month's count with Last.fm's
  #   (one request per month), and fully rechecks months whose counts differ. Equal counts are a
  #   discovery signal only: they never mark a month verified.
  #
  # The recurring tick (SyncScheduleJob, config/recurring.yml) calls `tick!`; it starts the most
  # important kind that is due for each eligible user. "Due" is measured from the last run of that
  # kind that *started*, whatever its outcome, so a failing kind is tried once per interval, never
  # in a loop. Duplicate or redelivered ticks are harmless: a user has at most one active run (a
  # unique index), and a run started moments ago isn't due again.
  #
  # Eligible: storage enabled; the full import completed and the connection is `imported` (a sync
  # that stopped for an account problem sets it to `failed`, and nothing more is scheduled until
  # an operator resumes it); the identity linked, not revoked and still allowed; no active run (an
  # import, a recheck or another sync waits for it to finish).
  module Sync
    KINDS = %w[reconcile catch_up sync].freeze # most important first
    class Busy < StandardError; end
    class NotEligible < StandardError; end

    module_function

    def config = Rails.configuration.x.history_sync

    def interval(kind)
      { "sync" => config[:sync_every], "catch_up" => config[:catch_up_every], "reconcile" => config[:reconcile_every] }.fetch(kind)
    end

    # Starts what is due for every eligible user. Returns { user_id => kind or reason }.
    def tick!(now: Time.current)
      HistoryImport.ensure_enabled!
      User.joins(:lastfm_connection).find_each.to_h do |user|
        ImportRun.uncached do
          reason = ineligible_reason(user)
          kind = reason ? nil : due_kind(user, now)
          [ user.id, reason || (kind ? start!(user, kind: kind, now: now).kind : :not_due) ]
        rescue Busy
          [ user.id, :busy ]
        end
      end
    end

    # The most important kind due now, or nil.
    def due_kind(user, now = Time.current)
      KINDS.find { |kind| due?(user, kind, now) }
    end

    # Measured from the last run of the kind, or from the end of the full import before the first
    # one. A minute's tolerance, so a tick that fires slightly early still counts.
    def due?(user, kind, now = Time.current)
      last = last_started(user, kind) || ImportRun.where(user_id: user.id, kind: "full", state: "completed").maximum(:finished_at)
      last.nil? || last <= now - interval(kind) + 1.minute
    end

    def last_started(user, kind)
      scope = ImportRun.where(user_id: user.id, kind: kind)
      scope = scope.where(count_scan: true) if kind == "reconcile" # not a person's recheck
      scope.maximum(:started_at)
    end

    # nil when the user may be synchronised; otherwise a symbol saying why not.
    def ineligible_reason(user)
      # Read now, not through the caller's (possibly long-held) associations.
      connection = LastfmConnection.find_by(user_id: user.id)
      identity = Identity.find_by(user_id: user.id, provider: Identity::LASTFM)
      return :not_imported unless connection&.history_state == "imported" && ImportRun.exists?(user_id: user.id, kind: "full", state: "completed")
      return :not_linked unless identity&.revoked_at.nil? && identity&.session_key
      return :not_allowed unless Lastfm::AccountPolicy.allowed?(identity.username)
      return :busy if ImportRun.active.exists?(user_id: user.id)

      nil
    end

    # Starts a run of `kind` for the user (the tick, or `bin/rails sync:run`).
    def start!(user, kind:, now: Time.current)
      HistoryImport.ensure_enabled!
      raise ArgumentError, "unknown sync kind #{kind}" unless KINDS.include?(kind)
      reason = ineligible_reason(user)
      raise Busy, "an import, check or sync is already running" if reason == :busy
      raise NotEligible, "cannot synchronise: #{reason}" if reason

      run = ImportRun.create!(user: user, kind: kind, state: "planning", started_at: now, count_scan: kind == "reconcile")
      Orchestrator.new(clock: -> { now }).schedule!(run, rotate_from: nil)
      run
    rescue ActiveRecord::RecordNotUnique
      raise Busy, "an import, check or sync is already running"
    end

    # The range a `sync` or `catch_up` run checks, from the frontier as it is now.
    def range_for(kind, user_id, now)
      target = (now - config[:settle]).utc.beginning_of_minute
      frontier = ImportWindow.live.where(user_id: user_id).maximum(:window_to) || target
      since = kind == "catch_up" ? target - config[:catch_up_span] : frontier - config[:lookback]
      [ [ since, target ].min, target ]
    end

    # After a sync stopped for an account problem and the operator fixed it (relinked): allow
    # synchronisation again. The next tick checks the account before anything is fetched.
    def resume!(user)
      return false unless ImportRun.exists?(user_id: user.id, kind: "full", state: "completed")

      LastfmConnection.where(user_id: user.id, history_state: "failed").update_all(history_state: "imported", last_error: nil, updated_at: Time.current) == 1
    end
  end
end
