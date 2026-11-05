module HistoryImport
  # One user's synchronisation health, for `GET /api/sync` and `bin/rails sync:status`. Coverage,
  # synchronisation and review stay separate: `coverage` and `missingPeriods` say what is imported,
  # `periods` counts per-period sync states (SyncStatus), `reviews` counts open review items, and
  # `attention` counts what needs the owner (HistoryImport::Attention's rules).
  #
  # Seven queries whatever the length of the history (docs/milestone-2-plan.md §15.7): the
  # connection, three about runs, and SyncStatus's three. `version` is one more query, cheap enough
  # to answer an unchanged request with 304 before any of this runs.
  module SyncHealth
    SYNC_KINDS = %w[sync catch_up reconcile].freeze

    VERSION_SQL = <<~SQL.squish.freeze
      SELECT GREATEST(
        (SELECT MAX(updated_at) FROM import_windows WHERE user_id = :user),
        (SELECT MAX(updated_at) FROM import_runs WHERE user_id = :user),
        (SELECT MAX(updated_at) FROM reconciliation_disputes WHERE user_id = :user),
        (SELECT MAX(updated_at) FROM scrobble_removals WHERE user_id = :user),
        (SELECT MAX(updated_at) FROM lastfm_connections WHERE user_id = :user))
    SQL

    module_function

    # Changes whenever anything this summary reports could have changed (and once a day, for
    # staleness and due times). For ETags.
    def version(user, now: Time.current)
      at = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([ VERSION_SQL, { user: user.id } ]))
      "#{at.respond_to?(:iso8601) ? at.iso8601(6) : at}:#{now.utc.to_date}:#{HistoryImport.enabled?}"
    end

    def for(user, now: Time.current)
      connection = LastfmConnection.find_by(user_id: user.id) # fresh, not the caller's cached association
      latest = latest_runs(user)
      import_finished_at = ImportRun.where(user_id: user.id, kind: "full", state: "completed").maximum(:finished_at)
      new_last_day = ImportRun.where(user_id: user.id, kind: SYNC_KINDS).where(started_at: (now - 24.hours)..).sum(:committed_scrobbles)
      months = SyncStatus.for(user, now: now)

      sync_runs = latest.values.select { |r| SYNC_KINDS.include?(r.kind) }
      last = sync_runs.max_by { |r| [ r.started_at || Time.at(0), r.id ] }
      active = latest.values.find { |r| ImportRun::ACTIVE_STATES.include?(r.state) }
      reviews = { disputes: months.sum(&:open_disputes), suspectedRemovals: months.sum(&:suspected_removals),
                  pendingRemovals: months.sum(&:pending_removals), reappeared: months.sum(&:reappeared) }
      actionable_reviews = reviews[:disputes] + reviews[:pendingRemovals] + reviews[:reappeared]
      actionable_periods = months.count { |m| Attention.actionable_period?(m) }
      # A failed Last.fm connection, or a listening source whose permission was lost (Attention).
      account_problem = (connection&.history_state == "failed" ? 1 : 0) + ListeningSource.where(user_id: user.id, state: "needs_reauth").count
      coverage = covered_ranges(months)
      {
        enabled: HistoryImport.enabled?,
        importComplete: import_finished_at.present?,
        connectionState: connection&.history_state,
        syncPaused: connection&.sync_paused_at.present?,
        activity: activity(active, connection),
        message: (connection.last_error if connection&.history_state == "failed"),
        lastSuccessfulSyncAt: connection&.last_synced_at&.iso8601,
        lastAttemptedSyncAt: last&.started_at&.iso8601,
        syncedThrough: months.map(&:to).max&.iso8601,
        coveredThrough: coverage.first&.end&.iso8601,
        coverage: coverage.map { |r| { from: r.begin.iso8601, to: r.end.iso8601 } },
        missingPeriods: missing_periods(months, coverage),
        activeRun: active && run_json(active),
        lastRun: last && run_json(last),
        newScrobbles: { lastRun: last&.committed_scrobbles.to_i, last24Hours: new_last_day },
        periods: months.group_by(&:status).transform_values(&:size),
        awaitingRecheck: months.count { |m| m.checking && m.imported } +
                         months.count { |m| !m.checking && m.remote_count && m.count_checked_at && m.remote_count != m.present_count &&
                                             (m.last_verified_at.nil? || m.last_verified_at < m.count_checked_at) },
        problemPeriods: months.select { |m| %i[check_stopped inconsistent].include?(m.status) }.map { |m| period_json(m) },
        stalePeriods: months.count { |m| m.status == :stale },
        reviews: reviews,
        attention: { reviews: actionable_reviews, periods: actionable_periods, account: account_problem,
                     total: actionable_reviews + actionable_periods + account_problem },
        nextDue: Sync::KINDS.to_h { |kind| [ kind, next_due(latest, kind, import_finished_at)&.iso8601 ] }
      }
    end

    # The latest run of each kind (a weekly reconcile apart from a person's recheck), in one query.
    def latest_runs(user)
      ImportRun.from(ImportRun.where(user_id: user.id).select("DISTINCT ON (kind, count_scan) import_runs.*")
                              .order(:kind, :count_scan, started_at: :desc, id: :desc), :import_runs)
               .to_a.index_by { |r| r.kind == "reconcile" && !r.count_scan ? "recheck" : r.kind }
    end

    # What the owner would want to know first, as a code the UI turns into a sentence.
    def activity(active, connection)
      return "sync_paused" if connection&.sync_paused_at && (active.nil? || active.kind != "full")
      return "idle" unless active
      return "paused" if active.state == "paused"
      return "waiting_for_review" if active.state == "needs_review"

      { "full" => "importing", "sync" => "syncing", "catch_up" => "catching_up", "reconcile" => "comparing" }.fetch(active.kind, "working")
    end

    # Imported ranges, adjacent windows merged, from the windows already loaded.
    def covered_ranges(months)
      months.select(&:imported).sort_by(&:from).each_with_object([]) do |m, merged|
        if merged.any? && m.from <= merged.last.end
          last = merged.pop
          merged << (last.begin...[ last.end, m.to ].max)
        else
          merged << (m.from...m.to)
        end
      end
    end

    # Ranges between the first period and the last that aren't imported, each with what is
    # happening to it: being imported, to be retried automatically, or waiting for a person.
    def missing_periods(months, coverage)
      return [] if months.empty?

      edges = [ months.map(&:from).min, *coverage.flat_map { |r| [ r.begin, r.end ] }, months.map(&:to).max ]
      gaps = edges.each_slice(2).filter_map { |from, to| (from...to) if from < to }
      gaps.map do |gap|
        inside = months.reject(&:imported).select { |m| m.from < gap.end && m.to > gap.begin }
        stopped = inside.find { |m| m.status == :check_stopped }
        { from: gap.begin.iso8601, to: gap.end.iso8601, state: gap_state(inside, stopped), reason: stopped && (stopped.review_reason || "gave_up"),
          message: stopped&.last_error }
      end
    end

    # needs_review: a person must look; retrying_later: an automatic retry is due later;
    # importing: being imported now.
    def gap_state(inside, stopped)
      return "needs_review" if inside.any? { |m| Attention.actionable_period?(m) }

      stopped ? "retrying_later" : "importing"
    end

    def period_json(m)
      { id: m.id, from: m.from.iso8601, to: m.to.iso8601, status: m.status, imported: m.imported,
        reason: m.review_reason || (m.state == "failed" ? "gave_up" : nil), message: m.last_error,
        retriesAutomatically: !Attention.actionable_period?(m), attempts: m.attempts, httpStatus: m.last_http_status,
        lastfmError: m.last_lastfm_error }
    end

    def run_json(run)
      { kind: run.kind == "reconcile" && !run.count_scan ? "recheck" : run.kind, state: run.state, startedAt: run.started_at&.iso8601,
        finishedAt: run.finished_at&.iso8601, checkedFrom: (run.history_from&.iso8601 unless run.kind == "full"),
        checkedTo: (run.cutoff_at&.iso8601 unless run.kind == "full"), newScrobbles: run.committed_scrobbles, error: run.last_error }
    end

    def next_due(latest, kind, import_finished_at)
      last = latest[kind]&.started_at || import_finished_at
      last && last + Sync.interval(kind)
    end
  end
end
