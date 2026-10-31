module Metadata
  # Queues identified artists for enrichment, most played first (docs/milestone-4-plan.md §5). An
  # artist counts as the catalogue entity at the end of its merge chain, so merged and inferred twins
  # add their plays to the artist they join and are never queued twice. Name-only artists have no
  # MBID and are never queued: nothing is searched by name. Queuing again updates priorities and
  # leaves states, attempts and due times as they are.
  module Planner
    module_function

    PLAYED_SQL = <<~SQL.freeze
      SELECT r.mbid, count(*) AS plays
        FROM scrobbles s
        JOIN name_variants v ON v.id = s.name_variant_id
        LEFT JOIN #{Catalogue::Roots.sql('artists')} root ON root.id = v.artist_id
        JOIN artists r ON r.id = COALESCE(root.root_id, v.artist_id)
       WHERE s.removed_at IS NULL AND r.mbid IS NOT NULL
       GROUP BY r.mbid
       ORDER BY plays DESC, r.mbid
    SQL

    # [[mbid, plays], ...] for identified artists with plays, most played first.
    def played_artists = ActiveRecord::Base.connection.select_rows(PLAYED_SQL)

    # Queues the `limit` most played (all when nil). Returns how many are queued in all.
    def plan!(limit: nil, now: Time.current)
      Enrichment.ensure_enabled!
      list = played_artists
      list = list.first(limit) if limit
      rows = list.map do |mbid, plays|
        { provider: Enrichment::PROVIDER, entity_kind: "artist", provider_id: mbid, priority: plays,
          status: "pending", next_attempt_at: now, created_at: now, updated_at: now }
      end
      rows.each_slice(1000) do |batch|
        MetadataTarget.upsert_all(batch, unique_by: :index_metadata_targets_identity, update_only: %i[priority])
      end
      MetadataTarget.where(entity_kind: "artist").count
    end
  end
end
