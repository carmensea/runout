module Metadata
  # Where enrichment stands: targets by state, and how many plays the enriched artists cover.
  module Progress
    module_function

    def report
      targets = MetadataTarget.where(provider: Enrichment::PROVIDER, entity_kind: "artist")
      by_status = targets.group(:status).count
      by_plays = targets.group(:status).sum(:priority)
      played = Planner.played_artists
      classified = GenreClassification.where(level: "artist", unclassified: false).pluck(:provider_id).to_set
      total_plays = played.sum { |_, n| n }
      {
        identified_artists: played.size,
        queued: targets.count,
        completed: by_status["ok"].to_i,
        unavailable: by_status["not_found"].to_i + by_status["invalid"].to_i,
        failed: by_status["failed"].to_i,
        remaining: targets.where(status: "pending").count,
        retrying: targets.where(status: "pending").where("attempts > 0").count,
        plays_of_identified_artists: total_plays,
        plays_enriched: by_plays["ok"].to_i,
        plays_classified: played.sum { |mbid, n| classified.include?(mbid) ? n : 0 },
        next_due: targets.where.not(status: "ok").minimum(:next_attempt_at),
        artwork: artwork
      }
    end

    # Artwork: what is eligible, queued, done and still to do, and what the last week brought. Every
    # queued release is in exactly one of `with_cover`, `without_cover` (none in the archive, asked
    # again after NEGATIVE), `waiting` (queued, not yet tried), `in_backoff` (tried, archive busy or
    # unreachable, retried on its own schedule) or `failed` (five tries in a row lost, retried after a
    # week). `due_now` is the next run's work; `refresh_due_30d` is how many finished covers come up
    # for their periodic check within a month, so a refresh wave can be seen coming. `inferred`
    # counts the per-user covers from ListenBrainz's mapping (Metadata::InferredArtwork), which have
    # no target.
    def artwork(now: Time.current)
      targets = MetadataTarget.where(provider: Artwork::PROVIDER)
      arts = MetadataArtwork.where(provider: Artwork::PROVIDER)
      found = arts.where.not(found_on: nil)
      eligible = Artwork.played_releases.size
      queued = targets.count
      pending = targets.where(status: "pending")
      { eligible: eligible, queued: queued, not_queued: [ eligible - queued, 0 ].max,
        with_cover: targets.where(status: "ok").count, on_release: found.where(found_on: "release").count,
        on_release_group: found.where(found_on: "release_group").count, without_cover: targets.where(status: "not_found").count,
        waiting: pending.where(attempts: 0).count, in_backoff: pending.where("attempts > 0").count, failed: targets.where(status: "failed").count,
        due_now: targets.where(next_attempt_at: ..now).count,
        refresh_due_30d: targets.where(status: "ok", next_attempt_at: now..(now + 30.days)).count,
        new_covers_7d: found.where(created_at: (now - 7.days)..).count,
        refreshed_7d: arts.where(fetched_at: (now - 7.days)..).where("fetched_at > created_at + interval '1 day'").count,
        fetch_problems_7d: MetadataFetch.where(provider: Artwork::PROVIDER, outcome: %w[error rate_limited], requested_at: (now - 7.days)..).count,
        last_fetch_at: arts.maximum(:fetched_at),
        inferred: ::InferredArtwork.group(:status).count }
    end
  end
end
