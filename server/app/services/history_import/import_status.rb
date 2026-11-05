module HistoryImport
  # `GET /api/import` (docs/milestone-2-plan.md §8.2, §15.3): what is stored, then the full import's progress for the
  # Settings import panel, in units the owner knows (scrobbles, periods), plus what stopped and what
  # is missing. Sync health is `GET /api/sync` (SyncHealth). A fixed number of queries.
  module ImportStatus
    SOURCES = %w[lastfm spotify listenbrainz].freeze
    STORED_SQL = ([ "count(*)", "min(played_at)", "max(played_at)" ] + SOURCES.map { |src| "count(*) FILTER (WHERE source = '#{src}')" }).join(", ").freeze

    module_function

    def for(user, now: Time.current)
      progress = Progress.for(user)
      run = ImportRun.where(user_id: user.id, kind: "full").order(:created_at, :id).last
      health = SyncHealth.for(user, now: now)
      current = progress.current_period if run&.working?
      {
        enabled: HistoryImport.enabled?,
        stored: stored(user),
        state: progress.state,
        complete: progress.complete,
        stalled: progress.stalled,
        activity: health[:activity],
        percent: progress.percent,
        importedScrobbles: progress.committed_scrobbles,
        lastfmPlaycount: progress.reported_playcount,
        historyFrom: progress.history_from&.iso8601,
        cutoffAt: progress.cutoff_at&.iso8601,
        currentPeriod: current && { from: current.begin.iso8601, to: current.end.iso8601 },
        periods: progress.windows,
        startedAt: run&.started_at&.iso8601,
        finishedAt: run&.finished_at&.iso8601,
        lastImportedAt: progress.last_committed_at&.iso8601,
        error: (progress.last_error if %w[failed needs_review].include?(progress.state)),
        failures: health[:problemPeriods],
        missingPeriods: health[:missingPeriods],
        attention: health[:attention][:total],
        canStart: HistoryImport.enabled? && (run.nil? || %w[cancelled failed].include?(run.state)) && !ImportRun.active.exists?(user_id: user.id)
      }
    end

    # The archive as it is, whatever recorded it: counts per source, first and latest play. Shown to
    # every account, with or without Last.fm.
    def stored(user)
      total, first, last, *by_source = Scrobble.present.where(user_id: user.id).pick(Arel.sql(STORED_SQL))
      sources = SOURCES.zip(by_source).to_h.reject { |_, n| n.to_i.zero? }
      { plays: total.to_i, firstPlayedAt: first&.iso8601, lastPlayedAt: last&.iso8601, sources: sources }
    end
  end
end
