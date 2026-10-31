module Analytics
  # The Overview for one user and one period (src/data/types.ts OverviewData), computed from
  # Runout's own listening history: stored plays and the catalogue. Nothing here knows which
  # service a play came from (docs/long-term-architecture.md).
  #
  # Rules (docs/milestone-3-plan.md):
  # - Counted: stored plays not removed by an approved review. Same-second plays count separately.
  # - Time: every play is placed in the user's reporting timezone by PostgreSQL's timezone
  #   database, so daylight saving time is handled per play. Weeks are ISO weeks (Monday first).
  # - Identity: the catalogue entity a play's names were matched to (merges followed); a play not
  #   matched (yet), or matched ambiguously, is grouped by its normalised names instead. Such
  #   plays are always counted and listed, never dropped. Albums: plays with no album name have
  #   no album. Names shown: the catalogue's, or the most played spelling.
  # - Coverage: whether the period lies within imported history; missing ranges are listed.
  # - Genres and artist metadata arrive in Milestone 4: they are null, never estimated.
  #
  # One transaction with temporary tables: each variant's identity (`ov_keys`, with integer ids
  # per artist, track and album), the period's plays as narrow rows of integers and local date
  # parts (`ov`), and each period artist's first play and last play before the period
  # (`ov_artists`). Aggregates run over integers; names and text ids are looked up only for
  # the rows returned (Milestone 3 benchmark: wide rows made every aggregate slow).
  class Overview
    TOP = 10
    TREND_POINTS = 12
    TWO_YEARS = 732 # days: week buckets are offered up to this (src/pages/overview/sections/ListeningSection.tsx)

    NORMALIZE = Identity::NORMALIZE

    KEYS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_keys ON COMMIT DROP AS
      WITH #{Identity.ctes("SELECT DISTINCT name_variant_id FROM scrobbles WHERE user_id = :user AND removed_at IS NULL")}
      -- Integer ids in order of name (then artist), so every tie is broken alphabetically and the
      -- results never depend on catalogue ids.
      SELECT id, artist_key, artist_name, track_key, track_name, album_key, album_name,
             dense_rank() OVER (ORDER BY artist_sort, artist_key)::int AS a,
             dense_rank() OVER (ORDER BY track_sort, artist_sort, track_key)::int AS t,
             CASE WHEN album_key IS NULL THEN NULL ELSE dense_rank() OVER (ORDER BY album_sort, artist_sort, album_key) END::int AS l
        FROM (SELECT keyed.*, min(lower(artist_name)) OVER (PARTITION BY artist_key) AS artist_sort,
                     min(lower(track_name)) OVER (PARTITION BY track_key) AS track_sort,
                     min(lower(album_name)) OVER (PARTITION BY album_key) AS album_sort
                FROM keyed) sorted
    SQL

    # The period's plays: one narrow row each, local date parts computed once.
    PLAYS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov ON COMMIT DROP AS
      SELECT utc, lt, lt::date AS d, (extract(year FROM lt) * 12 + extract(month FROM lt) - 1)::int AS mon,
             extract(isodow FROM lt)::smallint AS dow, extract(hour FROM lt)::smallint AS h, v, a, t, l
        FROM (SELECT s.played_at AS utc, (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz AS lt, k.id AS v, k.a, k.t, k.l
                FROM scrobbles s JOIN ov_keys k ON k.id = s.name_variant_id
               WHERE s.user_id = :user AND s.removed_at IS NULL AND s.played_at >= :from AND s.played_at < :to) plays
    SQL

    # History beyond the period matters only for the period's own artists (discovery, returns,
    # rediscovery), so only their variants are read. For `all`, the period is the history.
    PERIOD_VARIANTS = "SELECT k2.id FROM ov_keys k2 WHERE k2.a IN (SELECT DISTINCT a FROM ov)".freeze

    ARTISTS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_artists ON COMMIT DROP AS
      SELECT k.a, min(s.played_at) AS first_utc, max(s.played_at) FILTER (WHERE s.played_at < :from) AS last_before
        FROM scrobbles s JOIN ov_keys k ON k.id = s.name_variant_id
       WHERE s.user_id = :user AND s.removed_at IS NULL AND s.name_variant_id IN (#{PERIOD_VARIANTS})
       GROUP BY k.a
    SQL
    ALL_ARTISTS_SQL = "CREATE TEMP TABLE ov_artists ON COMMIT DROP AS SELECT a, min(utc) AS first_utc, NULL::timestamp AS last_before FROM ov GROUP BY a".freeze

    def initialize(user:, period:)
      @user = user
      @period = period
      @tz = user.reporting_timezone.presence || "UTC"
    end

    def call
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.uncached { build }
      end
    end

    private

    def build
      range = @period.utc_range(@tz)
      @from = range.begin || Time.utc(1970)
      @to = range.end || Time.utc(9999)
      # Dropped at commit; dropped here too in case this runs inside an outer transaction.
      exec("DROP TABLE IF EXISTS ov_keys, ov, ov_artists, ov_ga, ov_gaa")
      exec(KEYS_SQL, user: @user.id)
      exec(PLAYS_SQL, user: @user.id, tz: @tz, from: @from, to: @to)
      exec("ANALYZE ov_keys, ov")
      @period.all? ? exec(ALL_ARTISTS_SQL) : exec(ARTISTS_SQL, user: @user.id, from: @from)

      first_lt, last_lt, total = rows("SELECT min(lt), max(lt), count(*) FROM ov").first
      @dates = date_bounds(first_lt, last_lt)
      {
        period: @period.serialized,
        stats: stats(total, first_lt),
        activity: activity,
        mostActiveDays: most_active("d", ->(d) { d.iso8601 }),
        mostActiveMonths: most_active("mon", ->(m) { month_key(m) }),
        habits: habits,
        genres: genres,
        top: top_lists,
        rankHistory: rank_history,
        onRepeat: on_repeat,
        backInRotation: back_in_rotation,
        discovery: discovery,
        metadata: artist_metadata,
        nearestWithData: total.to_i.zero? ? nearest_with_data : [],
        coverage: coverage
      }
    end

    def exec(sql, **binds) = ActiveRecord::Base.connection.execute(bind(sql, binds))
    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(bind(sql, binds))

    # With no values to bind, the SQL is used as is (sanitize_sql_array would read `%` as a format).
    def bind(sql, binds) = binds.empty? ? sql : ActiveRecord::Base.sanitize_sql_array([ sql, binds ])

    def month_key(m) = format("%04d-%02d", m / 12, (m % 12) + 1)

    # --- names and ids, only for the rows returned --------------------------------------------

    COLUMNS = { a: [ "artist_key", "artist_name" ], t: [ "track_key", "track_name" ], l: [ "album_key", "album_name" ] }.freeze

    # { int id => [text key, most played name, most played artist name] } for the given ids.
    def labels(kind, ids)
      return {} if ids.empty?

      key, name = COLUMNS.fetch(kind)
      rows(<<~SQL, ids: ids.uniq).to_h { |id, k, n, artist| [ id, [ k, n, artist ] ] }
        SELECT ov.#{kind}, max(k.#{key}), mode() WITHIN GROUP (ORDER BY k.#{name}), mode() WITHIN GROUP (ORDER BY k.artist_name)
          FROM ov JOIN ov_keys k ON k.id = ov.v WHERE ov.#{kind} IN (:ids) GROUP BY 1
      SQL
    end

    # --- sections ----------------------------------------------------------------------------

    # The local dates the period covers: its own for a bounded period, the history's for `all`.
    def date_bounds(first_lt, last_lt)
      return @period.from..@period.to unless @period.all?
      return nil unless first_lt

      first_lt.to_date..last_lt.to_date
    end

    def stats(total, first_lt)
      artists, over_ten, tracks, once, albums = rows(<<~SQL).first
        WITH by_artist AS (SELECT a, count(*) AS n FROM ov GROUP BY a), by_track AS (SELECT t, count(*) AS n FROM ov GROUP BY t)
        SELECT (SELECT count(*) FROM by_artist), (SELECT count(*) FROM by_artist WHERE n > 10),
               (SELECT count(*) FROM by_track), (SELECT count(*) FROM by_track WHERE n = 1),
               (SELECT count(DISTINCT l) FROM ov)
      SQL
      { scrobbles: total.to_i, firstScrobbleDate: first_lt&.to_date&.iso8601, uniqueArtists: artists, artistsPlayedOverTen: over_ten,
        uniqueTracks: tracks, tracksPlayedOnce: once, uniqueAlbums: albums, albumsWithoutArtwork: nil }
    end

    # Buckets in order, every bucket of the period present (zero when nothing was played), each
    # with its most played artist.
    def activity
      { year: buckets("extract(year FROM lt)::int", dates_by(:year)) { |y| format("%04d", y) },
        month: buckets("mon", dates_by(:month)) { |m| month_key(m) },
        week: week_allowed? ? buckets(%q{to_char(lt, 'IYYY-"W"IW')}, dates_by(:week)) { |w| w } : nil }
    end

    def week_allowed? = !@period.all? && @dates && (@dates.last - @dates.first + 1) <= TWO_YEARS

    def dates_by(unit)
      return [] unless @dates

      keys = []
      date = @dates.first
      while date <= @dates.last
        keys << bucket_key(date, unit)
        date = next_bucket(date, unit)
      end
      keys.uniq
    end

    def bucket_key(date, unit)
      case unit
      when :year then format("%04d", date.year)
      when :month then format("%04d-%02d", date.year, date.month)
      when :week then format("%04d-W%02d", date.cwyear, date.cweek)
      end
    end

    def next_bucket(date, unit)
      case unit
      when :year then Date.new(date.year + 1, 1, 1)
      when :month then date.next_month.beginning_of_month
      when :week then date.beginning_of_week + 7
      end
    end

    # `bucket_sql` groups plays; the block turns a group value into its key.
    def buckets(bucket_sql, keys)
      top = rows(<<~SQL)
        SELECT DISTINCT ON (b) b, sum(n) OVER (PARTITION BY b), a
          FROM (SELECT #{bucket_sql} AS b, a, count(*) AS n FROM ov GROUP BY 1, 2) g
         ORDER BY b, n DESC, a
      SQL
      names = labels(:a, top.map(&:last))
      counts = top.to_h { |b, n, a| [ yield(b), [ n, names.dig(a, 1) ] ] }
      keys.map { |key| { key: key, scrobbles: counts.dig(key, 0).to_i, topArtist: counts.dig(key, 1) } }
    end

    def most_active(column, key)
      rows("SELECT #{column}, count(*) FROM ov GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT :limit", limit: TOP)
        .map { |value, n| { key: key.call(value), scrobbles: n } }
    end

    def habits
      by_hour = Array.new(24, 0)
      grid = Array.new(7) { Array.new(24, 0) }
      rows("SELECT dow, h, count(*) FROM ov GROUP BY 1, 2").each do |dow, hour, n|
        grid[dow - 1][hour] = n
        by_hour[hour] += n
      end
      { byHour: by_hour, byWeekday: grid.map(&:sum), byWeekdayHour: grid, avgPerDayByMonth: avg_per_day_by_month }
    end

    # For each calendar month (January first): scrobbles in that month of the year divided by the
    # days of that month the period covers.
    def avg_per_day_by_month
      return Array.new(12, 0.0) unless @dates

      days = Array.new(12, 0)
      @dates.each { |d| days[d.month - 1] += 1 }
      plays = Array.new(12, 0)
      rows("SELECT mon % 12, count(*) FROM ov GROUP BY 1").each { |m, n| plays[m] = n }
      plays.each_with_index.map { |n, i| days[i].zero? ? 0.0 : (n.to_f / days[i]).round(2) }
    end

    def top_lists
      { artists: top(:a, tracks_played: true), albums: top(:l, where: "l IS NOT NULL"), tracks: top(:t),
        totals: rows("SELECT count(DISTINCT a), count(DISTINCT l), count(DISTINCT t) FROM ov").first.then { |a, l, t| { artists: a, albums: l, tracks: t } } }
    end

    def top(kind, where: "TRUE", tracks_played: false)
      list = rows(<<~SQL, limit: TOP)
        SELECT #{kind}, count(*), min(lt), max(lt), #{tracks_played ? 'count(DISTINCT t)' : 'NULL'}
          FROM ov WHERE #{where} GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT :limit
      SQL
      return [] if list.empty?

      names = labels(kind, list.map(&:first))
      span = trend_span
      trends = Hash.new { |h, k| h[k] = Array.new(TREND_POINTS, 0) }
      rows(<<~SQL, ids: list.map(&:first), from: span.begin, to: span.end, points: TREND_POINTS).each do |id, b, n|
        SELECT #{kind}, width_bucket(extract(epoch FROM utc), extract(epoch FROM :from::timestamp), extract(epoch FROM :to::timestamp), :points), count(*)
          FROM ov WHERE #{kind} IN (:ids) GROUP BY 1, 2
      SQL
        trends[id][b - 1] = n if b.between?(1, TREND_POINTS)
      end
      # Ties in play count by name, so the order doesn't depend on internal ids.
      list.sort_by { |id, n| [ -n, names.dig(id, 1).to_s ] }.map do |id, n, first, last, distinct_tracks|
        key, title, by = names.fetch(id)
        { id: key, name: title, artist: kind == :a ? nil : by, tracksPlayed: distinct_tracks, imageUrl: nil, scrobbles: n,
          firstScrobble: first.to_date.iso8601, latestScrobble: last.to_date.iso8601, trend: trends[id].first(TREND_POINTS) }
      end
    end

    # The interval the trend points divide evenly: the period, or the history for `all`.
    def trend_span
      return @from...@to unless @period.all?

      first, last = rows("SELECT min(utc), max(utc) FROM ov").first
      first ? first...(last + 1) : Time.utc(1970)...Time.utc(1971)
    end

    # The period's top five artists, each one's rank among all artists every year (null outside
    # the top 10).
    def rank_history
      years = rows("SELECT DISTINCT extract(year FROM lt)::int FROM ov ORDER BY 1").flatten
      top_five = rows("SELECT a FROM ov GROUP BY 1 ORDER BY count(*) DESC, 1 LIMIT 5").flatten
      return { years: years, series: [] } if top_five.empty?

      names = labels(:a, top_five)
      ranks = rows(<<~SQL, ids: top_five).group_by(&:first)
        SELECT a, y, r FROM (
          SELECT a, y, rank() OVER (PARTITION BY y ORDER BY n DESC) AS r
            FROM (SELECT a, extract(year FROM lt)::int AS y, count(*) AS n FROM ov GROUP BY 1, 2) counts) ranked
         WHERE a IN (:ids)
      SQL
      { years: years,
        series: top_five.map do |a|
          by_year = ranks.fetch(a, []).to_h { |_, y, r| [ y, r ] }
          { id: names.dig(a, 0), name: names.dig(a, 1), ranks: years.map { |y| by_year[y]&.then { |r| r <= 10 ? r : nil } } }
        end }
    end

    def on_repeat
      list = rows("SELECT t, d, count(*) FROM ov GROUP BY 1, 2 HAVING count(*) > 1 ORDER BY 3 DESC, 2 DESC, 1 LIMIT 5")
      names = labels(:t, list.map(&:first))
      list.map { |t, day, n| { trackId: names.dig(t, 0), name: names.dig(t, 1), artist: names.dig(t, 2), plays: n, date: day.iso8601 } }
    end

    # Artists played again in this period after twelve months or more without a play. The month
    # before each played month is either an earlier month in the period or the artist's last play
    # before it, so no other history is needed.
    def back_in_rotation
      return [] unless @dates

      list = rows(<<~SQL, tz: @tz)
        SELECT a, m - prev - 1 AS away, m
          FROM (SELECT a, m, lag(m) OVER (PARTITION BY a ORDER BY m) AS prev, in_period
                  FROM (SELECT DISTINCT a, mon AS m, TRUE AS in_period FROM ov
                        UNION ALL
                        SELECT a, (extract(year FROM l) * 12 + extract(month FROM l) - 1)::int, FALSE
                          FROM (SELECT a, (last_before AT TIME ZONE 'UTC') AT TIME ZONE :tz AS l FROM ov_artists WHERE last_before IS NOT NULL) b) months) g
         WHERE in_period AND m - prev - 1 >= 12
      SQL
      names = labels(:a, list.map(&:first))
      list.sort_by { |a, away, back| [ -away, -back, names.dig(a, 1).to_s ] }.first(5)
          .map { |a, away, back| { id: names.dig(a, 0), name: names.dig(a, 1), awayMonths: away, backMonth: month_key(back) } }
    end

    def discovery
      per_month = rows(<<~SQL, tz: @tz, from: @from, to: @to).to_h { |m, n| [ m, n ] }
        SELECT to_char((first_utc AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM'), count(*)
          FROM ov_artists WHERE first_utc >= :from AND first_utc < :to GROUP BY 1
      SQL
      exploration = rows(<<~SQL).to_h { |m, share| [ month_key(m), share.to_f.round(4) ] }
        SELECT ov.mon, count(*) FILTER (WHERE ov.utc - a.first_utc <= interval '90 days')::float / count(*)
          FROM ov JOIN ov_artists a USING (a) GROUP BY 1
      SQL
      first_heard = rows(<<~SQL, tz: @tz, from: @from, to: @to, limit: TOP)
        SELECT a.a, to_char((a.first_utc AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM-DD'), p.n
          FROM ov_artists a JOIN (SELECT a, count(*) AS n FROM ov GROUP BY a) p USING (a)
         WHERE a.first_utc >= :from AND a.first_utc < :to
         ORDER BY 3 DESC, 1 LIMIT :limit
      SQL
      names = labels(:a, first_heard.map(&:first))
      { months: dates_by(:month).map { |m| { key: m, newArtists: per_month[m].to_i, explorationShare: exploration[m] || 0.0 } },
        firstHeard: first_heard.sort_by { |a, _, n| [ -n, names.dig(a, 1).to_s ] }
                               .map { |a, day, n| { id: names.dig(a, 0), name: names.dig(a, 1), firstScrobble: day, scrobbles: n } },
        rediscovered: rediscovered }
    end

    # Artists back this period after two years or more without a play (not for `all`).
    def rediscovered
      return [] if @period.all?

      list = rows(<<~SQL, tz: @tz)
        SELECT a.a, extract(year FROM (a.last_before AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int, extract(epoch FROM min(ov.utc) - a.last_before)
          FROM ov_artists a JOIN ov USING (a)
         WHERE a.last_before IS NOT NULL
         GROUP BY a.a, a.last_before
        HAVING min(ov.utc) - a.last_before >= interval '730 days'
      SQL
      names = labels(:a, list.map(&:first))
      list.sort_by { |a, _, gap| [ -gap, names.dig(a, 1).to_s ] }.first(5)
          .map { |a, year, _| { id: names.dig(a, 0), name: names.dig(a, 1), lastYearBefore: year } }
    end

    # For an empty period: the nearest months before and after it that have plays.
    def nearest_with_data
      before, after = rows(<<~SQL, user: @user.id, from: @from, to: @to, tz: @tz).first
        SELECT to_char((max(played_at) FILTER (WHERE played_at < :from) AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM'),
               to_char((min(played_at) FILTER (WHERE played_at >= :to) AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM')
          FROM scrobbles WHERE user_id = :user AND removed_at IS NULL
      SQL
      [ before, after ].compact.map { |m| "month:#{m}" }
    end

    # --- genres and artist metadata (Milestone 4) -------------------------------------------------

    # Null until enrichment has classified anything: nothing is shown as known before it is.
    def genres
      return nil unless GenreClassification.where(level: "artist").exists?

      GenreFigures.new(->(sql, **binds) { rows(sql, **binds) }, ->(ids) { labels(:a, ids).transform_values { |key, name, _| [ key, name ] } }).call
    end

    def artist_metadata
      return nil unless MetadataArtist.exists?

      plays = rows(<<~SQL).to_h { |key, n| [ key, n.to_i ] }
        SELECT k.artist_key, sum(c.n) FROM (SELECT a, count(*) AS n FROM ov GROUP BY a) c
          JOIN (SELECT DISTINCT a, artist_key FROM ov_keys) k USING (a)
         GROUP BY 1
      SQL
      ArtistKinds.call(plays)
    end

    # Whether the period lies within imported history (Analytics::Coverage).
    def coverage
      @period.all? ? Coverage.new(@user, @tz).for(nil, nil) : Coverage.new(@user, @tz).for(@from, @to)
    end
  end
end
