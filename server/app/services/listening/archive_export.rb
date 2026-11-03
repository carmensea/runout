module Listening
  # Everything a source recorded, as a portable file, for merging into another Runout database
  # (docs/railway-deployment.md §6). One JSON object per line, ending with a line count and checksum.
  # Read-only. Holds no credentials.
  class ArchiveExport
    FORMAT = 1

    def initialize(source) = @source = source

    def write(io)
      digest = Digest::SHA256.new
      lines = 0
      emit = lambda do |record|
        line = record.to_json
        digest << line
        lines += 1
        io.puts line
      end

      emit.call(type: "header", format: FORMAT, provider: @source.provider, account: @source.external_account_id,
                covered_from: @source.covered_from, high_water_at: @source.high_water_at, last_new_play_at: @source.last_new_play_at,
                exported_at: Time.current, database: ApplicationRecord.connection.current_database)
      observations.find_each { |o| emit.call(observation(o)) }
      ids = observations.pluck(:id, :source_event_id).to_h
      ReviewDecision.where(subject_type: "ListeningObservation", subject_id: ids.keys).find_each do |d|
        emit.call(type: "decision", source_event_id: ids.fetch(d.subject_id), action: d.action, source: d.source, details: d.details, created_at: d.created_at)
      end
      @source.polls.find_each { |p| emit.call(type: "poll", row: p.attributes.except("id", "listening_source_id", "user_id")) }
      @source.gaps.includes(:listening_poll).find_each do |g|
        emit.call(type: "gap", poll_started_at: g.listening_poll&.started_at, row: g.attributes.except("id", "listening_source_id", "user_id", "listening_poll_id"))
      end
      other_decisions.each { |table, row| emit.call(type: "other_decision", table: table, row: row) }
      io.puts({ type: "end", lines: lines, sha256: digest.hexdigest }.to_json)
    end

    private

    def observations = ListeningObservation.where(listening_source: @source).includes(:name_variant, :scrobble)

    # Decisions a merge can't apply by itself, because their IDs mean nothing in another database.
    # Carried in the file and reported, never dropped silently.
    def other_decisions
      rows = ReviewDecision.where.not(subject_type: "ListeningObservation").map { |d| [ "review_decisions", d.attributes ] }
      rows += CatalogueReview.where.not(state: "open").map { |r| [ "catalogue_reviews", r.attributes ] }
      rows + MetadataOverride.all.map { |o| [ "metadata_overrides", o.attributes ] }
    end

    def observation(o)
      v = o.name_variant
      { type: "observation", source_event_id: o.source_event_id, reported_at_raw: o.reported_at_raw, timestamp_kind: o.timestamp_kind,
        duration_ms: o.duration_ms, artist_name: v.artist_name, track_name: v.track_name, album_name: v.album_name,
        provider_track_id: o.provider_track_id, provider_album_id: o.provider_album_id, provider_artist_ids: o.provider_artist_ids,
        isrc: o.isrc, context: o.context, link_state: o.link_state, linked_by: o.linked_by, match_evidence: o.match_evidence,
        received_at: o.received_at, last_seen_at: o.last_seen_at, times_seen: o.times_seen, later_values: o.later_values,
        scrobble_played_at: o.scrobble&.played_at, scrobble_seq: o.scrobble&.seq, scrobble_removed_at: o.scrobble&.removed_at }
    end
  end
end
