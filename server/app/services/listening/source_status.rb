module Listening
  # What Settings shows about listening sources (docs/spotify-plan.md §7, §10). Provider sync status
  # only: the Last.fm import's coverage is reported separately (HistoryImport::ImportStatus).
  # Never credentials.
  module SourceStatus
    RECENT_POLLS = 5

    module_function

    def for(user)
      source = user.listening_sources.spotify.order(Arel.sql("state = 'disconnected'"), updated_at: :desc).first
      lb = user.listening_sources.where(provider: "listenbrainz").order(Arel.sql("state = 'disconnected'"), updated_at: :desc).first
      {
        lastfm: { role: "archive", connected: user.lastfm_identity.present?, username: user.lastfm_identity&.username },
        spotify: spotify(source),
        listenbrainz: listenbrainz(lb)
      }
    end

    # The ListenBrainz connection: a verified username, never a token (there is none to show).
    def listenbrainz(source)
      base = { enabled: ListeningStorage.enabled?("listenbrainz") }
      return base.merge(state: "not_connected", account: nil) unless source

      base.merge(state: source.state, account: { id: source.external_account_id, displayName: source.display_name },
                 connectedAt: source.connected_at.iso8601, disconnectedAt: source.disconnected_at&.iso8601,
                 paused: source.paused?, lastPollAt: source.last_poll_at&.iso8601, lastSuccessAt: source.last_success_at&.iso8601,
                 nextPollAt: source.next_poll_at&.iso8601, lastNewPlayAt: source.last_new_play_at&.iso8601, playsAdded: source.plays_added,
                 newestPlayAt: source.high_water_at&.iso8601, coveredFrom: source.covered_from&.iso8601,
                 lastError: source.last_error, lastErrorAt: source.last_error_at&.iso8601,
                 pendingReview: ListeningObservation.where(listening_source_id: source.id, link_state: "pending_review").count,
                 backfill: source.backfill_state && { state: source.backfill_state, fetched: source.backfill_fetched, total: source.backfill_total,
                                                       before: source.backfill_before&.iso8601, startedAt: source.backfill_started_at&.iso8601,
                                                       finishedAt: source.backfill_finished_at&.iso8601 },
                 recentPolls: recent_polls(source))
    end

    def spotify(source)
      base = { configured: Spotify::Config.configured?, ingestionEnabled: ListeningStorage.enabled?("spotify"),
               pollSchedule: ENV.fetch("SPOTIFY_POLL_SCHEDULE", "every 5 minutes") }
      return base.merge(state: "not_connected", account: nil) unless source

      base.merge(
        state: source.state, account: { id: source.external_account_id, displayName: source.display_name },
        connectedAt: source.connected_at.iso8601, disconnectedAt: source.disconnected_at&.iso8601,
        paused: source.paused?, lastPollAt: source.last_poll_at&.iso8601, lastSuccessAt: source.last_success_at&.iso8601,
        nextPollAt: source.next_poll_at&.iso8601, lastNewPlayAt: source.last_new_play_at&.iso8601, playsAdded: source.plays_added,
        newestPlayAt: source.high_water_at&.iso8601, coveredFrom: source.covered_from&.iso8601,
        lastError: source.last_error, lastErrorAt: source.last_error_at&.iso8601,
        pendingReview: ListeningObservation.where(listening_source_id: source.id, link_state: "pending_review").count,
        gaps: source.gaps.open.order(:gap_from).map { |g| { from: g.gap_from.iso8601, to: g.gap_to.iso8601, detectedAt: g.detected_at.iso8601 } },
        recentPolls: recent_polls(source)
      )
    end

    def recent_polls(source)
      source.polls.order(started_at: :desc).limit(RECENT_POLLS).map do |p|
        { startedAt: p.started_at.iso8601, trigger: p.trigger, outcome: p.outcome || "running", items: p.items,
          added: p.recorded.fetch("created", 0), linked: p.recorded.fetch("linked", 0), held: p.recorded.fetch("pending_review", 0),
          error: p.error }
      end
    end
  end
end
