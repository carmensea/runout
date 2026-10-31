module Analytics
  # One genre in a period (GET /api/genres/:slug; docs/milestone-4-plan.md §3, §7): how many plays
  # it gets (allocated: each play split over its artist's genres, so allocations across genres add up
  # to the plays), its share, its reach (plays by artists with any of this genre; overlapping, never
  # summed with other genres), its subgenres, the artists and tracks contributing most, and the same
  # per year. Artist-level: a track counts with its artist's genres.
  #
  # Sums are PostgreSQL's, over plays per catalogue artist and year (`gd_pa`). Name-only artists have
  # no genres, so they count only in the totals; identity keys are built only for the plays of
  # artists contributing to the genre, for the track ranking (Milestone 4 benchmark).
  class GenreDetail
    TOP = 10

    PREPARE_SQL = <<~SQL.freeze
      CREATE TEMP TABLE gd_pa ON COMMIT DROP AS
      SELECT pa.a, pa.y, pa.n, gc.unclassified IS FALSE AS classified,
             COALESCE((CASE WHEN :broad THEN gc.broad ELSE gc.sub END ->> :slug)::float8, 0) AS share,
             COALESCE(:slug = ANY (gc.present), false) AS reaches, gc.sub
        FROM (SELECT COALESCE(root.root_id, v.artist_id) AS a,
                     extract(year FROM (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int AS y, count(*) AS n
                FROM scrobbles s
                JOIN name_variants v ON v.id = s.name_variant_id
                LEFT JOIN #{Catalogue::Roots.sql('artists')} root ON root.id = v.artist_id
               WHERE s.user_id = :user AND s.removed_at IS NULL AND s.played_at >= :from AND s.played_at < :to
               GROUP BY 1, 2) pa
        LEFT JOIN artists ar ON ar.id = pa.a
        LEFT JOIN genre_classifications gc ON gc.level = 'artist' AND gc.provider_id = ar.mbid
    SQL

    # The contributing artists' plays, by track identity (the Overview's keys).
    TRACKS_SQL = <<~SQL.freeze
      WITH contributing AS (SELECT a, max(share) AS share FROM gd_pa WHERE share > 0 GROUP BY a),
      pv AS (
        SELECT s.name_variant_id AS v, count(*) AS n
          FROM scrobbles s
          JOIN name_variants v ON v.id = s.name_variant_id
          LEFT JOIN #{Catalogue::Roots.sql('artists')} root ON root.id = v.artist_id
         WHERE s.user_id = :user AND s.removed_at IS NULL AND s.played_at >= :from AND s.played_at < :to
           AND COALESCE(root.root_id, v.artist_id) IN (SELECT a FROM contributing)
         GROUP BY 1
      ),
      #{Identity.ctes('SELECT v AS name_variant_id FROM pv')}
      SELECT k.track_key, sum(pv.n * c.share) AS alloc, mode() WITHIN GROUP (ORDER BY k.track_name), mode() WITHIN GROUP (ORDER BY k.artist_name)
        FROM pv JOIN keyed k ON k.id = pv.v
        JOIN contributing c ON 'a' || c.a = k.artist_key
       GROUP BY 1
       ORDER BY alloc DESC, 3
       LIMIT :top
    SQL

    class UnknownGenre < StandardError; end

    def initialize(user:, period:, slug:)
      @user = user
      @period = period
      @genre = Genre.includes(:parent, :subgenres).find_by(slug: slug) or raise UnknownGenre, slug
      @tz = user.reporting_timezone.presence || "UTC"
    end

    def call
      ActiveRecord::Base.transaction { ActiveRecord::Base.uncached { build } }
    end

    private

    def build
      range = @period.utc_range(@tz)
      @binds = { user: @user.id, tz: @tz, from: range.begin || Time.utc(1970), to: range.end || Time.utc(9999),
                 slug: @genre.slug, broad: @genre.level == "broad", top: TOP }
      exec("DROP TABLE IF EXISTS gd_pa")
      exec(PREPARE_SQL)
      years = rows(<<~SQL)
        SELECT y, sum(n), sum(n * share), sum(n) FILTER (WHERE reaches), sum(n) FILTER (WHERE classified)
          FROM gd_pa GROUP BY 1 ORDER BY 1
      SQL
      plays = years.sum { |r| r[1].to_i }
      allocated = years.sum { |r| r[2].to_f }
      reach = years.sum { |r| r[3].to_i }
      classified = years.sum { |r| r[4].to_i }

      {
        period: @period.serialized,
        genre: { slug: @genre.slug, name: @genre.name, level: @genre.level,
                 parent: @genre.parent && { slug: @genre.parent.slug, name: @genre.parent.name } },
        plays: plays,
        allocated: allocated.round(2),
        share: plays.zero? ? 0.0 : allocated / plays,
        reach: { plays: reach, share: plays.zero? ? 0.0 : reach.to_f / plays },
        unclassifiedShare: plays.zero? ? 0.0 : (plays - classified).to_f / plays,
        subgenres: @genre.level == "broad" ? subgenres(plays) : [],
        topArtists: top_artists,
        topTracks: allocated.positive? ? rows(TRACKS_SQL).map { |key, v, name, artist| { id: key, name: name, artist: artist, allocated: v.to_f.round(1) } } : [],
        byYear: years.map do |y, n, alloc, r, _|
          { year: y.to_i, plays: n.to_i, allocated: alloc.to_f.round(1), share: n.to_i.zero? ? 0.0 : alloc.to_f / n.to_i,
            reachShare: n.to_i.zero? ? 0.0 : r.to_f / n.to_i }
        end,
        methodology: { level: "artist", provider: "MusicBrainz", license: "CC BY-NC-SA 3.0", url: "https://musicbrainz.org" }
      }
    end

    def top_artists
      rows(<<~SQL).map { |a, n, alloc, name| { id: "a#{a}", name: name, allocated: alloc.to_f.round(1), plays: n.to_i, genreShare: alloc.to_f / n.to_i } }
        SELECT g.a, sum(g.n), sum(g.n * g.share) AS alloc, max(ar.name)
          FROM gd_pa g JOIN artists ar ON ar.id = g.a
         WHERE g.share > 0
         GROUP BY 1
         ORDER BY alloc DESC, 4
         LIMIT :top
      SQL
    end

    def subgenres(plays)
      names = @genre.subgenres.to_h { |g| [ g.slug, g.name ] }.merge("other:#{@genre.slug}" => "Other #{@genre.name.downcase}")
      rows(<<~SQL, keys: names.keys).map do |slug, v|
        SELECT e.key, sum(n * e.value::float8) AS v
          FROM gd_pa CROSS JOIN LATERAL jsonb_each_text(sub) e
         WHERE classified AND e.key IN (:keys)
         GROUP BY 1
         ORDER BY v DESC, 1
      SQL
        { slug: slug.start_with?("other:") ? nil : slug, name: names.fetch(slug), allocated: v.to_f.round(1), share: plays.zero? ? 0.0 : v.to_f / plays }
      end
    end

    def exec(sql) = ActiveRecord::Base.connection.execute(bind(sql, @binds))
    def rows(sql, **extra) = ActiveRecord::Base.connection.select_rows(bind(sql, @binds.merge(extra)))

    # Genre keys (which contain colons) only ever arrive as bound values.
    def bind(sql, binds) = ActiveRecord::Base.sanitize_sql_array([ sql, binds ])
  end
end
