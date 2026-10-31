module Analytics
  # How a play is identified, shared by every view of the history (docs/milestone-3-plan.md §1):
  # its catalogue artist, track and album at the end of their merge chains, or, where not matched,
  # its normalised names. SQL only; one row per name variant.
  module Identity
    NORMALIZE = ->(column) { "lower(normalize(btrim(regexp_replace(#{column}, '\\s+', ' ', 'g')), NFKC))" }

    # Each variant's artist, track and album, and (`arm`, `trm`, `alm`) the entity each is merged
    # into at the end of its chain, if any (Catalogue::Roots).
    ROOT_JOINS = <<~SQL.squish.freeze
      LEFT JOIN artists ar ON ar.id = v.artist_id
      LEFT JOIN #{Catalogue::Roots.sql('artists')} ar_root ON ar_root.id = ar.id LEFT JOIN artists arm ON arm.id = ar_root.root_id
      LEFT JOIN tracks tr ON tr.id = v.track_id
      LEFT JOIN #{Catalogue::Roots.sql('tracks')} tr_root ON tr_root.id = tr.id LEFT JOIN tracks trm ON trm.id = tr_root.root_id
      LEFT JOIN albums al ON al.id = v.album_id
      LEFT JOIN #{Catalogue::Roots.sql('albums')} al_root ON al_root.id = al.id LEFT JOIN albums alm ON alm.id = al_root.root_id
    SQL

    # CTEs `used` (the given query of name variant ids), `named` and `keyed`. `keyed` has id,
    # artist_key, artist_name, track_key, track_name, album_key, album_name per variant: the keys
    # ("a…"/"n…", "t…"/"m…", "l…"/"o…") the Overview, Search and Time Machine share.
    def self.ctes(used_sql)
      <<~SQL
        used AS (#{used_sql}),
        named AS (
          SELECT v.id,
                 COALESCE('a' || COALESCE(arm.id, ar.id), 'n' || md5(#{NORMALIZE.call('v.artist_name')})) AS artist_key,
                 COALESCE(arm.name, ar.name, v.artist_name) AS artist_name,
                 tr.id AS track_id, trm.id AS track_merged, COALESCE(trm.title, tr.title, v.track_name) AS track_name,
                 #{NORMALIZE.call('v.track_name')} AS track_norm,
                 al.id AS album_id, alm.id AS album_merged, COALESCE(alm.title, al.title, NULLIF(btrim(v.album_name), '')) AS album_name,
                 #{NORMALIZE.call('v.album_name')} AS album_norm
            FROM used
            JOIN name_variants v ON v.id = used.name_variant_id
            #{ROOT_JOINS}
        ),
        keyed AS (
          SELECT id, artist_key, artist_name,
                 COALESCE('t' || COALESCE(track_merged, track_id), 'm' || md5(artist_key || '|' || track_norm)) AS track_key, track_name,
                 CASE WHEN album_id IS NOT NULL THEN 'l' || COALESCE(album_merged, album_id)
                      WHEN album_norm = '' THEN NULL
                      ELSE 'o' || md5(artist_key || '|' || album_norm) END AS album_key,
                 album_name
            FROM named
        )
      SQL
    end
  end
end
