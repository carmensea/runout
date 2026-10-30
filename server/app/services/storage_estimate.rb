# Synthetic storage measurement for the history schema (docs/milestone-2-plan.md §2, §6.5). Inserts
# generated rows with plain SQL inside a transaction, reads pg_total_relation_size (tables plus
# indexes plus TOAST), and always rolls back. Shapes: about one distinct name variant per five
# plays, a long-tail catalogue, and one full staging window.
module StorageEstimate
  # Every table the estimate writes to, all expected to be empty beforehand.
  EMPTY_CHECK_SQL = <<~SQL.freeze
    SELECT NOT EXISTS (SELECT 1 FROM scrobble_removals) AND NOT EXISTS (SELECT 1 FROM scrobble_corrections)
       AND NOT EXISTS (SELECT 1 FROM scrobbles) AND NOT EXISTS (SELECT 1 FROM import_window_rows)
       AND NOT EXISTS (SELECT 1 FROM import_window_fetches) AND NOT EXISTS (SELECT 1 FROM import_windows)
       AND NOT EXISTS (SELECT 1 FROM import_runs) AND NOT EXISTS (SELECT 1 FROM name_variants)
       AND NOT EXISTS (SELECT 1 FROM tracks) AND NOT EXISTS (SELECT 1 FROM albums) AND NOT EXISTS (SELECT 1 FROM artists)
       AND NOT EXISTS (SELECT 1 FROM catalogue_reviews) AND NOT EXISTS (SELECT 1 FROM artist_aliases)
  SQL
  TRUNCATE_SQL = <<~SQL.freeze
    TRUNCATE scrobble_removals, scrobble_corrections, scrobbles, import_window_rows, import_window_fetches,
             import_windows, import_runs, catalogue_reviews, artist_aliases, name_variants, tracks, albums, artists
  SQL

  # Values are bound through sanitize_sql_array (named placeholders), never interpolated.
  STATEMENTS = [
    <<~SQL,
      INSERT INTO artists (name, normalized_name, mbid, created_at, updated_at)
      SELECT 'Synthetic Artist ' || g, 'synthetic artist ' || g, CASE WHEN g % 3 <> 0 THEN gen_random_uuid()::text END, now(), now()
      FROM generate_series(1, :artists) g
    SQL
    <<~SQL,
      INSERT INTO albums (artist_id, title, normalized_title, mbid, created_at, updated_at)
      SELECT (SELECT min(id) FROM artists) + (g % :artists), 'Synthetic Album Title ' || g, 'synthetic album title ' || g,
             CASE WHEN g % 2 = 0 THEN gen_random_uuid()::text END, now(), now()
      FROM generate_series(1, :albums) g
    SQL
    <<~SQL,
      INSERT INTO tracks (artist_id, title, normalized_title, mbid, created_at, updated_at)
      SELECT (SELECT min(id) FROM artists) + (g % :artists), 'Synthetic Track Name ' || g, 'synthetic track name ' || g,
             CASE WHEN g % 3 <> 0 THEN gen_random_uuid()::text END, now(), now()
      FROM generate_series(1, :tracks) g
    SQL
    <<~SQL,
      INSERT INTO name_variants (variant_hash, artist_name, track_name, album_name, artist_mbid, track_mbid, album_mbid,
                                 artist_id, album_id, track_id, match_method, matched_at, created_at)
      SELECT sha256(('v' || g)::bytea), 'Synthetic Artist ' || (g % :artists), 'Synthetic Track Name ' || g,
             CASE WHEN g % 4 = 0 THEN '' ELSE 'Synthetic Album Title ' || (g % :albums) END,
             CASE WHEN g % 3 <> 0 THEN gen_random_uuid()::text END, CASE WHEN g % 3 <> 0 THEN gen_random_uuid()::text END,
             CASE WHEN g % 2 = 0 THEN gen_random_uuid()::text END,
             (SELECT min(id) FROM artists) + (g % :artists), (SELECT min(id) FROM albums) + (g % :albums),
             (SELECT min(id) FROM tracks) + (g % :tracks), 'normalized_name', now(), now()
      FROM generate_series(1, :variants) g
    SQL
    <<~SQL,
      INSERT INTO scrobbles (user_id, played_at, seq, name_variant_id, created_at)
      SELECT :user_id, timestamp '2004-08-07' + (g * interval '1 second' * 3650), 0,
             (SELECT min(id) FROM name_variants) + (g % :variants), now()
      FROM generate_series(1, :scrobbles) g
    SQL
    <<~SQL,
      INSERT INTO import_windows (user_id, window_from, window_to, state, created_at, updated_at)
      VALUES (:user_id, '2014-03-01', '2014-04-01', 'fetching', now(), now())
    SQL
    <<~SQL,
      INSERT INTO import_window_fetches (import_window_id, attempt, started_at, created_at, updated_at)
      SELECT id, 1, now(), now(), now() FROM import_windows WHERE user_id = :user_id
    SQL
    <<~SQL
      INSERT INTO import_window_rows (import_window_fetch_id, played_at, position, occurrence, variant_hash,
                                      artist_name, track_name, album_name, artist_mbid, track_mbid, album_mbid)
      SELECT (SELECT max(id) FROM import_window_fetches), timestamp '2014-03-01' + g * interval '600 seconds', 0, 0,
             sha256(('r' || g)::bytea), 'Synthetic Artist ' || g, 'Synthetic Track Name ' || g, 'Synthetic Album Title ' || g,
             gen_random_uuid()::text, NULL, NULL
      FROM generate_series(1, 4000) g
    SQL
  ].freeze

  module_function

  def run(scrobbles:)
    raise "Refusing to run in production." if Rails.env.production?

    conn = ActiveRecord::Base.connection
    lines = []
    conn.transaction(requires_new: true) do # savepoint: the rollback holds even inside an outer transaction
      variants = [ scrobbles / 5, 1 ].max
      artists = [ variants / 10, 1 ].max
      albums = [ variants * 3 / 10, 1 ].max
      tracks = [ variants * 85 / 100, 1 ].max

      # Measure on fresh storage. Rolled-back inserts leave dead pages behind until VACUUM, so earlier
      # runs would otherwise inflate the sizes. TRUNCATE inside the transaction gives each table new,
      # empty files, and the rollback restores the originals. Only allowed when they hold nothing.
      raise "Refusing to run: history tables are not empty." unless conn.select_value(EMPTY_CHECK_SQL)

      conn.execute(TRUNCATE_SQL)

      user_id = conn.select_value("INSERT INTO users (display_name, created_at, updated_at) VALUES ('storage-estimate', now(), now()) RETURNING id")
      params = { user_id: user_id, scrobbles: Integer(scrobbles), variants: variants, artists: artists, albums: albums, tracks: tracks }
      STATEMENTS.each { |sql| conn.execute(ActiveRecord::Base.sanitize_sql_array([ sql, params ])) }
      conn.execute("ANALYZE")

      sizes = StorageReport.rows
      sizes.reject { |row| row.rows.zero? }.each do |row|
        lines << format("%-22s %9d rows %10s", row.table, row.rows, ActiveSupport::NumberHelper.number_to_human_size(row.bytes))
      end
      per = StorageReport.total_bytes(sizes) / scrobbles.to_f
      lines << format("%-22s %14s %10s  (%.0f bytes per scrobble, all tables)", "total", "",
                      ActiveSupport::NumberHelper.number_to_human_size(StorageReport.total_bytes(sizes)), per)
      raise ActiveRecord::Rollback
    end
    lines
  end
end
