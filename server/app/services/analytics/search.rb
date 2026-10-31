module Analytics
  # Search over the signed-in user's own listening history (src/data/types.ts SearchResults):
  # artists, albums and tracks they have stored plays of. Never anything only another user played:
  # every candidate must have one of this user's plays that isn't removed.
  #
  # Matching is case-insensitive on normalised names: partial matches (anywhere in the name), and
  # misspellings through trigram similarity (pg_trgm's `%`, threshold 0.3). Order: exact name, then names starting with
  # the query, then names containing it, then by similarity; ties by how often the user played it.
  #
  # Ids are the same identity keys as the Overview's (Analytics::Overview): catalogue entities
  # where matched, otherwise the normalised-name fallback, so unmatched plays can be found too.
  class Search
    LIMIT = 5
    MIN_LENGTH = 2

    NORMALIZE = Overview::NORMALIZE
    ARTIST_KEY = "COALESCE('a' || COALESCE(ar.merged_into_id, ar.id), 'n' || md5(#{NORMALIZE.call('v.artist_name')}))".freeze
    ARTIST_NAME = "COALESCE(arm.name, ar.name, v.artist_name)".freeze
    JOINS = <<~SQL.freeze
      JOIN scrobbles s ON s.name_variant_id = v.id AND s.user_id = :user AND s.removed_at IS NULL
      LEFT JOIN artists ar ON ar.id = v.artist_id LEFT JOIN artists arm ON arm.id = ar.merged_into_id
    SQL

    def initialize(user:, query:)
      @user = user
      @query = CatalogName.normalize(query).first(100)
    end

    def call
      return { artists: [], albums: [], tracks: [] } if @query.length < MIN_LENGTH

      ActiveRecord::Base.uncached do
        { artists: artists.map { |id, name| { id: id, name: name } },
          albums: albums.map { |id, name, artist| { id: id, name: name, artist: artist } },
          tracks: tracks.map { |id, name, artist| { id: id, name: name, artist: artist } } }
      end
    end

    private

    # Variants whose names match (through the indexes), then the user's plays of them, grouped by
    # identity. `name_sql` is the matched entity's normalised name for ranking.
    def search(match_sql, key_sql, name_sql, display_sql, artist_sql)
      rows(<<~SQL)
        SELECT key, name, artist FROM (
          SELECT #{key_sql} AS key, max(#{display_sql}) AS name, max(#{artist_sql}) AS artist, count(*) AS plays,
                 max(#{name_sql}) AS norm
            FROM name_variants v
            #{JOINS}
           WHERE v.id IN (#{match_sql})
           GROUP BY 1) hits
         ORDER BY (norm = :q) DESC, (norm LIKE :prefix) DESC, (norm LIKE :contains) DESC,
                  similarity(norm, :q) DESC, plays DESC, name
         LIMIT :limit
      SQL
    end

    def binds
      like = ActiveRecord::Base.sanitize_sql_like(@query)
      { user: @user.id, q: @query, prefix: "#{like}%", contains: "%#{like}%", limit: LIMIT }
    end

    # Name-matching variants: through the catalogue's names where matched, the raw strings otherwise.
    def matching(catalogue_table, catalogue_column, variant_fk, variant_column)
      <<~SQL
        SELECT v2.id FROM name_variants v2 JOIN #{catalogue_table} c ON c.id = v2.#{variant_fk}
         WHERE c.#{catalogue_column} LIKE :contains OR c.#{catalogue_column} % :q
        UNION
        SELECT v3.id FROM name_variants v3
         WHERE v3.#{variant_fk} IS NULL
           AND (lower(v3.#{variant_column}) LIKE :contains OR lower(v3.#{variant_column}) % :q)
      SQL
    end

    def artists
      search(matching("artists", "normalized_name", "artist_id", "artist_name"), ARTIST_KEY, NORMALIZE.call(ARTIST_NAME), ARTIST_NAME, "NULL")
    end

    def tracks
      key = "COALESCE('t' || COALESCE(tr.merged_into_id, tr.id), 'm' || md5(#{ARTIST_KEY} || '|' || #{NORMALIZE.call('v.track_name')}))"
      name = "COALESCE(trm.title, tr.title, v.track_name)"
      rows(entity_sql("tracks", "tr", "trm", "track_id", key, name, matching("tracks", "normalized_title", "track_id", "track_name")))
    end

    def albums
      key = "CASE WHEN al.id IS NOT NULL THEN 'l' || COALESCE(al.merged_into_id, al.id) " \
            "ELSE 'o' || md5(#{ARTIST_KEY} || '|' || #{NORMALIZE.call('v.album_name')}) END"
      name = "COALESCE(alm.title, al.title, NULLIF(btrim(v.album_name), ''))"
      rows(entity_sql("albums", "al", "alm", "album_id", key, name, matching("albums", "normalized_title", "album_id", "album_name"),
                      where: "btrim(v.album_name) <> '' OR v.album_id IS NOT NULL"))
    end

    def rows(sql) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))

    # Tracks and albums: as `search`, with the entity's own (merged) row joined for its title.
    def entity_sql(table, alias_name, merged_alias, fk, key, name, match_sql, where: "TRUE")
      <<~SQL
        SELECT key, name, artist FROM (
          SELECT #{key} AS key, max(#{name}) AS name, max(#{ARTIST_NAME}) AS artist, count(*) AS plays,
                 max(#{NORMALIZE.call(name)}) AS norm
            FROM name_variants v
            #{JOINS}
            LEFT JOIN #{table} #{alias_name} ON #{alias_name}.id = v.#{fk}
            LEFT JOIN #{table} #{merged_alias} ON #{merged_alias}.id = #{alias_name}.merged_into_id
           WHERE v.id IN (#{match_sql}) AND (#{where})
           GROUP BY 1) hits
         ORDER BY (norm = :q) DESC, (norm LIKE :prefix) DESC, (norm LIKE :contains) DESC,
                  similarity(norm, :q) DESC, plays DESC, name
         LIMIT :limit
      SQL
    end
  end
end
