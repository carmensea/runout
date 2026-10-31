module Listening
  # Reports held for a person (docs/spotify-plan.md §5), with the plays they might be.
  module ReviewQueue
    LIMIT = 50

    module_function

    def for(user)
      items = ListeningObservation.pending_review.where(user_id: user.id).includes(:name_variant).order(:reported_at).limit(LIMIT).to_a
      ids = items.flat_map { |o| Array(o.match_evidence["candidates"]).map { |c| c["scrobble_id"] } }
      stored = Scrobble.where(id: ids, user_id: user.id).includes(:name_variant).index_by(&:id)
      items.map do |o|
        { id: o.id, provider: o.provider, reportedAt: o.reported_at.iso8601(3), durationMs: o.duration_ms, reason: o.match_evidence["reason"],
          play: names(o.name_variant),
          candidates: Array(o.match_evidence["candidates"]).filter_map do |c|
            s = stored[c["scrobble_id"]] or next
            { scrobbleId: s.id, source: s.source, playedAt: s.played_at.iso8601, identity: c["identity"], present: s.removed_at.nil?, **names(s.name_variant) }
          end }
      end
    end

    def names(variant) = { artist: variant.artist_name, track: variant.track_name, album: variant.album_name.presence }
  end
end
