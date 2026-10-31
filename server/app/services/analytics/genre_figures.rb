module Analytics
  # A period's genre figures for the Overview (src/data/types.ts GenreBreakdown; docs/backend-plan.md
  # §6, docs/milestone-4-plan.md §3). Runs inside Analytics::Overview's transaction, on its temporary
  # tables: plays per artist and local year (`ov_ga`), joined to each artist's classification. The
  # sums are PostgreSQL's, so the work grows with artists and genres, not plays (Milestone 4 benchmark).
  #
  # Every play counts once: shares, Unclassified included, add up to 1, in the period and in every
  # year. Unclassified is broken down by reason. The level is the artist's: artist genres approximate
  # the music played.
  class GenreFigures
    SLOTS = 6
    TOP_ARTISTS = 5
    REASONS = { "not_identified" => "notIdentified", "not_looked_up" => "notLookedUp", "no_genres" => "noGenres" }.freeze

    # Plays per artist and year with what is known about the artist. `status`: classified,
    # no_genres, not_looked_up or not_identified (Analytics::ArtistProfiles).
    PREPARE_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_ga ON COMMIT DROP AS
      SELECT c.a, c.y, c.n, gc.broad, gc.sub,
             CASE WHEN ar.mbid IS NULL THEN 'not_identified'
                  WHEN gc.unclassified IS FALSE THEN 'classified'
                  WHEN gc.provider_id IS NULL AND ma.provider_id IS NULL THEN 'not_looked_up'
                  ELSE 'no_genres' END AS status
        FROM (SELECT a, mon / 12 AS y, count(*) AS n FROM ov GROUP BY 1, 2) c
        JOIN (SELECT DISTINCT a, artist_key FROM ov_keys) k USING (a)
        LEFT JOIN artists ar ON k.artist_key LIKE 'a%' AND ar.id = substr(k.artist_key, 2)::bigint
        LEFT JOIN genre_classifications gc ON gc.level = 'artist' AND gc.provider_id = ar.mbid
        LEFT JOIN metadata_artists ma ON ma.provider = 'musicbrainz' AND ma.provider_id = ar.mbid
    SQL

    # `query`: runs SQL with binds and returns rows (Overview#rows); `names`: display names by `a`.
    def initialize(query, names)
      @query = query
      @names = names
      @genres = Genre.includes(:parent).index_by(&:slug)
    end

    # The same per artist, over all years: what the rankings need, with far fewer rows than ov_ga.
    PER_ARTIST_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_gaa ON COMMIT DROP AS
      SELECT a, sum(n) AS n, min(broad::text)::jsonb AS broad, min(sub::text)::jsonb AS sub, min(status) AS status FROM ov_ga GROUP BY a
    SQL

    def call
      @query.call("DROP TABLE IF EXISTS ov_ga, ov_gaa")
      @query.call(PREPARE_SQL)
      @query.call(PER_ARTIST_SQL)
      # sum() of integers is numeric, which arrives as BigDecimal and would leave as a JSON string.
      @years = @query.call("SELECT y, sum(n), sum(n) FILTER (WHERE status = 'classified') FROM ov_ga GROUP BY 1 ORDER BY 1")
                     .map { |y, n, classified| [ y.to_i, n.to_i, classified.to_i ] }
      @plays = @years.sum { |_, n, _| n }
      @reasons = @query.call("SELECT status, sum(n) FROM ov_ga GROUP BY 1").to_h { |s, n| [ s, n.to_i ] }
      broad = breakdown("broad")
      sub = breakdown("sub")
      named = (broad[:categories] + sub[:categories]).flat_map { |c| c[:topArtists] }
      names = @names.call(named.map { |a| a[:a] }.uniq)
      named.each do |artist|
        key, name = names.fetch(artist.delete(:a))
        artist.merge!(id: key, name: name)
      end
      { broad: broad, sub: sub, level: "artist",
        source: { provider: "MusicBrainz", license: "CC BY-NC-SA 3.0", url: "https://musicbrainz.org" } }
    end

    private

    def breakdown(column)
      return { categories: [], untaggedShare: 0.0, unclassified: REASONS.values.index_with(0.0), byYear: [] } if @plays.zero?

      by_year = @query.call(<<~SQL)
        SELECT y, e.key, sum(n * e.value::float8)
          FROM ov_ga CROSS JOIN LATERAL jsonb_each_text(#{column}) e
         WHERE status = 'classified'
         GROUP BY 1, 2
      SQL
      allocated = Hash.new(0.0)
      by_year = by_year.map { |y, slug, v| [ y.to_i, slug, v.to_f ] }
      by_year.each { |_, slug, v| allocated[slug] += v }
      ranked = allocated.sort_by { |slug, v| [ -v, slug ] }.map(&:first)
      shown = ranked.first(SLOTS)
      rest = ranked.drop(SLOTS)
      tops = top_artists(column, shown, rest)

      categories = shown.map do |slug|
        { id: slug, name: name(slug), share: allocated[slug] / @plays, subgenres: column == "broad" ? subgenres_of(slug) : [],
          topArtists: tops.fetch(slug, []) }
      end
      if rest.any?
        categories << { id: "other", name: column == "broad" ? "Other genres" : "Other subgenres", share: rest.sum { |s| allocated[s] } / @plays,
                        subgenres: [], topArtists: tops.fetch("other", []) }
      end
      unclassified = @plays - @years.sum { |_, _, classified| classified }
      { categories: categories, untaggedShare: unclassified.to_f / @plays,
        unclassified: REASONS.to_h { |status, name| [ name, @reasons[status].to_f / @plays ] },
        byYear: year_shares(by_year, shown) }
    end

    # Each year's shares by the period's own slots, so the bands are continuous; each year adds up to 1.
    def year_shares(by_year, shown)
      per_year = by_year.group_by(&:first)
      @years.map do |year, total, classified|
        shares = Hash.new(0.0)
        per_year.fetch(year, []).each { |_, slug, v| shares[shown.include?(slug) ? slug : "other"] += v / total }
        shares["untagged"] = (total - classified).to_f / total if total > classified
        { year: year, shares: shares }
      end
    end

    # The artists contributing most to each shown genre, and to the rest together ("other").
    def top_artists(column, shown, rest)
      return {} if shown.empty?

      # Genre keys contain colons ("other:rock"), so they are bound, never written into the SQL.
      @query.call(<<~SQL, top: TOP_ARTISTS, shown: shown, all: shown + rest).group_by(&:first)
        SELECT g, a, alloc FROM (
          SELECT g, a, alloc, row_number() OVER (PARTITION BY g ORDER BY alloc DESC, a) AS rk
            FROM (SELECT CASE WHEN e.key IN (:shown) THEN e.key ELSE 'other' END AS g, a, sum(n * e.value::float8) AS alloc
                    FROM ov_gaa CROSS JOIN LATERAL jsonb_each_text(#{column}) e
                   WHERE status = 'classified' AND e.key IN (:all)
                   GROUP BY 1, 2) t
        ) ranked
         WHERE rk <= :top
         ORDER BY g, rk
      SQL
            .transform_values { |list| list.map { |_, a, v| { a: a, scrobbles: v.to_f.round } } }
    end

    def subgenres_of(slug)
      @subs ||= @query.call(<<~SQL).group_by { |s, _| @genres[s]&.parent&.slug }
        SELECT e.key, sum(n * e.value::float8) AS v
          FROM ov_gaa CROSS JOIN LATERAL jsonb_each_text(sub) e
         WHERE status = 'classified' AND e.key NOT LIKE 'other:%'
         GROUP BY 1 ORDER BY v DESC, 1
      SQL
      @subs.fetch(slug, []).first(6).map { |s, _| @genres[s].name }
    end

    def name(slug)
      return "Other #{@genres.fetch(slug.delete_prefix('other:')).name.downcase}" if slug.start_with?("other:")

      @genres.fetch(slug).name
    end
  end
end
