module HistoryImport
  # One user's synchronisation health, for `GET /api/sync` and `bin/rails sync:status`. Coverage,
  # synchronisation and review stay separate here too: `syncedThrough` is where committed coverage
  # ends, `periods` counts per-period sync states (SyncStatus), `reviews` counts open review items.
  module SyncHealth
    module_function

    def for(user, now: Time.current)
      months = SyncStatus.for(user, now: now)
      connection = LastfmConnection.find_by(user_id: user.id) # fresh, not the caller's cached association
      sync_runs = ImportRun.where(user_id: user.id, kind: %w[sync catch_up reconcile])
      last = sync_runs.order(:started_at, :id).last
      active = ImportRun.active.find_by(user_id: user.id)
      {
        enabled: HistoryImport.enabled?,
        importComplete: ImportRun.exists?(user_id: user.id, kind: "full", state: "completed"),
        connectionState: connection&.history_state,
        message: (connection.last_error if connection&.history_state == "failed"),
        lastSuccessfulSyncAt: connection&.last_synced_at&.iso8601,
        lastAttemptedSyncAt: last&.started_at&.iso8601,
        syncedThrough: ImportCoverage.ranges(user).last&.end&.iso8601,
        activeRun: active && run_json(active),
        lastRun: last && run_json(last),
        newScrobbles: { lastRun: last&.committed_scrobbles.to_i,
                        last24Hours: sync_runs.where(started_at: (now - 24.hours)..).sum(:committed_scrobbles) },
        periods: months.group_by(&:status).transform_values(&:size),
        awaitingRecheck: months.count { |m| m.checking && m.imported } +
                         months.count { |m| !m.checking && m.remote_count && m.count_checked_at && m.remote_count != m.present_count &&
                                             (m.last_verified_at.nil? || m.last_verified_at < m.count_checked_at) },
        problemPeriods: months.select { |m| %i[check_stopped inconsistent].include?(m.status) || (!m.imported && !m.checking) }
                              .map { |m| { from: m.from.iso8601, to: m.to.iso8601, status: m.status, message: m.last_error } },
        stalePeriods: months.count { |m| m.status == :stale },
        reviews: { disputes: months.sum(&:open_disputes), suspectedRemovals: months.sum(&:suspected_removals),
                   pendingRemovals: months.sum(&:pending_removals), reappeared: months.sum(&:reappeared) },
        nextDue: Sync::KINDS.to_h { |kind| [ kind, next_due(user, kind)&.iso8601 ] }
      }
    end

    def run_json(run)
      { kind: run.kind, state: run.state, startedAt: run.started_at&.iso8601, finishedAt: run.finished_at&.iso8601,
        checkedFrom: (run.history_from&.iso8601 unless run.kind == "full"), checkedTo: (run.cutoff_at&.iso8601 unless run.kind == "full"),
        newScrobbles: run.committed_scrobbles, error: run.last_error }
    end

    def next_due(user, kind)
      last = Sync.last_started(user, kind) || ImportRun.where(user_id: user.id, kind: "full", state: "completed").maximum(:finished_at)
      last && last + Sync.interval(kind)
    end
  end
end
