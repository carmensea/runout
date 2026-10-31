module Metadata
  # Where enrichment stands: targets by state, and how many plays the enriched artists cover.
  module Progress
    module_function

    def report
      targets = MetadataTarget.where(entity_kind: "artist")
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
        next_due: targets.where.not(status: "ok").minimum(:next_attempt_at)
      }
    end
  end
end
