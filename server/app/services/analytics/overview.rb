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
  # One transaction with three temporary tables: each variant's identity (`ov_keys`), the
  # period's plays (`ov`), and per-artist history across all time (`ov_artists`, `ov_artist_months`,
  # for discovery and returns).
  class Overview
    TOP = 10
    TREND_POINTS = 12
    TWO_YEARS = 732 # days: week buckets are offered up to this (src/pages/overview/sections/ListeningSection.tsx)

    NORMALIZE = ->(column) { "lower(normalize(btrim(regexp_replace(#{column}, '\\s+', ' ', 'g')), NFKC))" }

    KEYS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_keys ON COMMIT DROP AS
      WITH used AS (SELECT DISTINCT name_variant_id FROM scrobbles WHERE user_id = :user AND removed_at IS NULL),
      named AS (
        SELECT v.id,
               COALESCE('a' || COALESCE(ar.merged_into_id, ar.id), 'n' || md5(#{NORMALIZE.call('v.artist_name')})) AS artist_key,
               COALESCE(arm.name, ar.name, v.artist_name) AS artist_name,
               tr.id AS track_id, tr.merged_into_id AS track_merged, COALESCE(trm.title, tr.title, v.track_name) AS track_name,
               #{NORMALIZE.call('v.track_name')} AS track_norm,
               al.id AS album_id, al.merged_into_id AS album_merged, COALESCE(alm.title, al.title, NULLIF(btrim(v.album_name), '')) AS album_name,
               #{NORMALIZE.call('v.album_name')} AS album_norm
          FROM used
          JOIN name_variants v ON v.id = used.name_variant_id
          LEFT JOIN artists ar ON ar.id = v.artist_id LEFT JOIN artists arm ON arm.id = ar.merged_into_id
          LEFT JOIN tracks tr ON tr.id = v.track_id LEFT JOIN tracks trm ON trm.id = tr.merged_into_id
          LEFT JOIN albums al ON al.id = v.album_id LEFT JOIN albums alm ON alm.id = al.merged_into_id
      )
      SELECT id, artist_key, artist_name,
             COALESCE('t' || COALESCE(track_merged, track_id), 'm' || md5(artist_key || '|' || track_norm)) AS track_key, track_name,
             CASE WHEN album_id IS NOT NULL THEN 'l' || COALESCE(album_merged, album_id)
                  WHEN album_norm = '' THEN NULL
                  ELSE 'o' || md5(artist_key || '|' || album_norm) END AS album_key,
             album_name
        FROM named
    SQL

    PLAYS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov ON COMMIT DROP AS
      SELECT s.played_at AS utc, (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz AS lt,
             k.artist_key, k.artist_name, k.track_key, k.track_name, k.album_key, k.album_name
        FROM scrobbles s JOIN ov_keys k ON k.id = s.name_variant_id
       WHERE s.user_id = :user AND s.removed_at IS NULL AND s.played_at >= :from AND s.played_at < :to
    SQL

    # Per artist over all history: first play, last play before the period.
    ARTISTS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_artists ON COMMIT DROP AS
      SELECT k.artist_key, min(s.played_at) AS first_utc, max(s.played_at) FILTER (WHERE s.played_at < :from) AS last_before
        FROM scrobbles s JOIN ov_keys k ON k.id = s.name_variant_id
       WHERE s.user_id = :user AND s.removed_at IS NULL
       GROUP BY k.artist_key
    SQL

    # Per artist, the local months they were played in, over all history (as month numbers).
    ARTIST_MONTHS_SQL = <<~SQL.freeze
      CREATE TEMP TABLE ov_artist_months ON COMMIT DROP AS
      SELECT DISTINCT k.artist_key,
             (extract(year FROM (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz) * 12
              + extract(month FROM (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz) - 1)::int AS m
        FROM scrobbles s JOIN ov_keys k ON k.id = s.name_variant_id
       WHERE s.user_id = :user AND s.removed_at IS NULL
    SQL

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
      exec("DROP TABLE IF EXISTS ov_keys, ov, ov_artists, ov_artist_months")
      exec(KEYS_SQL, user: @user.id)
      exec(PLAYS_SQL, user: @user.id, tz: @tz, from: @from, to: @to)
      exec(ARTISTS_SQL, user: @user.id, from: @from)
      exec(ARTIST_MONTHS_SQL, user: @user.id, tz: @tz)
      exec("ANALYZE ov")

      first_lt, last_lt, total = rows("SELECT min(lt), max(lt), count(*) FROM ov").first
      @dates = date_bounds(first_lt, last_lt)
      {
        period: @period.serialized,
        stats: stats(total, first_lt),
        activity: activity,
        mostActiveDays: most_active("YYYY-MM-DD"),
        mostActiveMonths: most_active("YYYY-MM"),
        habits: habits,
        genres: nil,
        top: top_lists,
        rankHistory: rank_history,
        onRepeat: on_repeat,
        backInRotation: back_in_rotation,
        discovery: discovery,
        metadata: nil,
        nearestWithData: total.to_i.zero? ? nearest_with_data : [],
        coverage: coverage
      }
    end

    def exec(sql, **binds) = ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))

    # The local dates the period covers: its own for a bounded period, the history's for `all`.
    def date_bounds(first_lt, last_lt)
      return @period.from..@period.to unless @period.all?
      return nil unless first_lt

      first_lt.to_date..last_lt.to_date
    end

    def stats(total, first_lt)
      artists, over_ten, tracks, once, albums = rows(<<~SQL).first
        SELECT (SELECT count(DISTINCT artist_key) FROM ov),
               (SELECT count(*) FROM (SELECT 1 FROM ov GROUP BY artist_key HAVING count(*) > 10) a),
               (SELECT count(DISTINCT track_key) FROM ov),
               (SELECT count(*) FROM (SELECT 1 FROM ov GROUP BY track_key HAVING count(*) = 1) t),
               (SELECT count(DISTINCT album_key) FROM ov)
      SQL
      { scrobbles: total.to_i, firstScrobbleDate: first_lt&.to_date&.iso8601, uniqueArtists: artists, artistsPlayedOverTen: over_ten,
        uniqueTracks: tracks, tracksPlayedOnce: once, uniqueAlbums: albums, albumsWithoutArtwork: nil }
    end

    # Buckets in order, every bucket of the period present (zero when nothing was played), each
    # with its most played artist.
    def activity
      { year: buckets("YYYY", dates_by(:year)), month: buckets("YYYY-MM", dates_by(:month)),
        week: week_allowed? ? buckets('IYYY-"W"IW', dates_by(:week)) : nil }
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

    def buckets(format, keys)
      counts = rows(<<~SQL, format: format).to_h { |key, n, artist| [ key, [ n, artist ] ] }
        SELECT DISTINCT ON (key) key, sum(n) OVER (PARTITION BY key), artist_name
          FROM (SELECT to_char(lt, :format) AS key, artist_key, mode() WITHIN GROUP (ORDER BY artist_name) AS artist_name, count(*) AS n
                  FROM ov GROUP BY 1, 2) b
         ORDER BY key, n DESC, artist_name
      SQL
      keys.map { |key| { key: key, scrobbles: counts.dig(key, 0).to_i, topArtist: counts.dig(key, 1) } }
    end

    def most_active(format)
      rows(<<~SQL, format: format, limit: TOP).map { |key, n| { key: key, scrobbles: n } }
        SELECT to_char(lt, :format), count(*) FROM ov GROUP BY 1 ORDER BY 2 DESC, 1 LIMIT :limit
      SQL
    end

    def habits
      by_hour = Array.new(24, 0)
      grid = Array.new(7) { Array.new(24, 0) }
      rows("SELECT extract(isodow FROM lt)::int, extract(hour FROM lt)::int, count(*) FROM ov GROUP BY 1, 2").each do |dow, hour, n|
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
      rows("SELECT extract(month FROM lt)::int, count(*) FROM ov GROUP BY 1").each { |m, n| plays[m - 1] = n }
      plays.each_with_index.map { |n, i| days[i].zero? ? 0.0 : (n.to_f / days[i]).round(2) }
    end

    def top_lists
      { artists: top("artist_key", "mode() WITHIN GROUP (ORDER BY artist_name)", "NULL", tracks_played: true),
        albums: top("album_key", "mode() WITHIN GROUP (ORDER BY album_name)", "mode() WITHIN GROUP (ORDER BY artist_name)", where: "album_key IS NOT NULL"),
        tracks: top("track_key", "mode() WITHIN GROUP (ORDER BY track_name)", "mode() WITHIN GROUP (ORDER BY artist_name)"),
        totals: rows(<<~SQL).first.then { |a, l, t| { artists: a, albums: l, tracks: t } } }
          SELECT count(DISTINCT artist_key), count(DISTINCT album_key), count(DISTINCT track_key) FROM ov
        SQL
    end

    def top(key, name, artist, where: "TRUE", tracks_played: false)
      span = trend_span
      list = rows(<<~SQL, limit: TOP)
        SELECT #{key}, #{name}, #{artist}, count(*), min(lt), max(lt), #{tracks_played ? 'count(DISTINCT track_key)' : 'NULL'}
          FROM ov WHERE #{where} GROUP BY 1 ORDER BY 4 DESC, 2 LIMIT :limit
      SQL
      return [] if list.empty?

      trends = Hash.new { |h, k| h[k] = Array.new(TREND_POINTS, 0) }
      rows(<<~SQL, keys: list.map(&:first), from: span.begin, to: span.end, points: TREND_POINTS).each { |k, b, n| trends[k][b - 1] = n if b.between?(1, TREND_POINTS) }
        SELECT #{key}, width_bucket(extract(epoch FROM utc), extract(epoch FROM :from::timestamp), extract(epoch FROM :to::timestamp), :points), count(*)
          FROM ov WHERE #{key} IN (:keys) GROUP BY 1, 2
      SQL
      list.map do |id, title, by, n, first, last, distinct_tracks|
        { id: id, name: title, artist: by, tracksPlayed: distinct_tracks, imageUrl: nil, scrobbles: n,
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
      top_five = rows("SELECT artist_key, mode() WITHIN GROUP (ORDER BY artist_name) FROM ov GROUP BY 1 ORDER BY count(*) DESC, 2 LIMIT 5")
      return { years: years, series: [] } if top_five.empty?

      ranks = rows(<<~SQL, keys: top_five.map(&:first)).group_by(&:first)
        SELECT artist_key, y, r FROM (
          SELECT artist_key, y, rank() OVER (PARTITION BY y ORDER BY n DESC) AS r
            FROM (SELECT artist_key, extract(year FROM lt)::int AS y, count(*) AS n FROM ov GROUP BY 1, 2) counts) ranked
         WHERE artist_key IN (:keys)
      SQL
      { years: years,
        series: top_five.map do |key, name|
          by_year = ranks.fetch(key, []).to_h { |_, y, r| [ y, r ] }
          { id: key, name: name, ranks: years.map { |y| by_year[y]&.then { |r| r <= 10 ? r : nil } } }
        end }
    end

    def on_repeat
      rows(<<~SQL, limit: 5).map { |key, name, artist, n, day| { trackId: key, name: name, artist: artist, plays: n, date: day } }
        SELECT track_key, mode() WITHIN GROUP (ORDER BY track_name), mode() WITHIN GROUP (ORDER BY artist_name), count(*), to_char(lt, 'YYYY-MM-DD')
          FROM ov GROUP BY track_key, to_char(lt, 'YYYY-MM-DD') HAVING count(*) > 1
         ORDER BY 4 DESC, 5 DESC LIMIT :limit
      SQL
    end

    # Artists played again in this period after twelve months or more without a play.
    def back_in_rotation
      return [] unless @dates

      first_m = (@dates.first.year * 12) + @dates.first.month - 1
      last_m = (@dates.last.year * 12) + @dates.last.month - 1
      rows(<<~SQL, from_m: first_m, to_m: last_m, limit: 5).map do |key, name, away, back|
        SELECT g.artist_key, (SELECT mode() WITHIN GROUP (ORDER BY artist_name) FROM ov WHERE ov.artist_key = g.artist_key), g.m - g.prev - 1 AS away, g.m
          FROM (SELECT artist_key, m, lag(m) OVER (PARTITION BY artist_key ORDER BY m) AS prev FROM ov_artist_months) g
         WHERE g.m BETWEEN :from_m AND :to_m AND g.m - g.prev - 1 >= 12
           AND EXISTS (SELECT 1 FROM ov WHERE ov.artist_key = g.artist_key)
         ORDER BY 3 DESC, 4 DESC, 2 LIMIT :limit
      SQL
        { id: key, name: name, awayMonths: away, backMonth: format("%04d-%02d", back / 12, (back % 12) + 1) }
      end
    end

    def discovery
      months = dates_by(:month)
      per_month = rows(<<~SQL, tz: @tz, from: @from, to: @to).to_h { |m, n| [ m, n ] }
        SELECT to_char((first_utc AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM'), count(*)
          FROM ov_artists WHERE first_utc >= :from AND first_utc < :to GROUP BY 1
      SQL
      exploration = rows(<<~SQL).to_h { |m, share| [ m, share.to_f.round(4) ] }
        SELECT to_char(ov.lt, 'YYYY-MM'),
               count(*) FILTER (WHERE ov.utc - a.first_utc <= interval '90 days')::float / count(*)
          FROM ov JOIN ov_artists a USING (artist_key) GROUP BY 1
      SQL
      first_heard = rows(<<~SQL, tz: @tz, from: @from, to: @to, limit: TOP)
        SELECT a.artist_key, mode() WITHIN GROUP (ORDER BY ov.artist_name), to_char((a.first_utc AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM-DD'), count(*)
          FROM ov_artists a JOIN ov USING (artist_key)
         WHERE a.first_utc >= :from AND a.first_utc < :to
         GROUP BY a.artist_key, a.first_utc ORDER BY 4 DESC, 2 LIMIT :limit
      SQL
      { months: months.map { |m| { key: m, newArtists: per_month[m].to_i, explorationShare: exploration[m] || 0.0 } },
        firstHeard: first_heard.map { |key, name, day, n| { id: key, name: name, firstScrobble: day, scrobbles: n } },
        rediscovered: rediscovered }
    end

    # Artists back this period after two years or more without a play (not for `all`).
    def rediscovered
      return [] if @period.all?

      rows(<<~SQL, tz: @tz, limit: 5).map { |key, name, year| { id: key, name: name, lastYearBefore: year } }
        SELECT a.artist_key, mode() WITHIN GROUP (ORDER BY ov.artist_name), extract(year FROM (a.last_before AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int
          FROM ov_artists a JOIN ov USING (artist_key)
         WHERE a.last_before IS NOT NULL
         GROUP BY a.artist_key, a.last_before
        HAVING min(ov.utc) - a.last_before >= interval '730 days'
         ORDER BY min(ov.utc) - a.last_before DESC, 2 LIMIT :limit
      SQL
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

    # Whether the period lies within imported history (ImportCoverage). `none`: nothing of it is
    # imported; `partial`: some is; `complete`: all of it. Missing ranges in local dates.
    def coverage
      covered = ImportCoverage.ranges(@user)
      return { status: "none", missing: [] } if covered.empty?

      from = @period.all? ? covered.first.begin : @from
      to = @period.all? ? covered.last.end : [ @to, Time.current ].min
      return { status: "complete", missing: [] } if to <= from

      edges = [ from, *covered.flat_map { |r| [ r.begin.clamp(from, to), r.end.clamp(from, to) ] }, to ]
      gaps = edges.each_slice(2).filter_map { |a, b| (a...b) if a < b }
      tz = Period.zone(@tz)
      missing = gaps.map { |g| { from: g.begin.in_time_zone(tz).to_date.iso8601, to: (g.end - 1).in_time_zone(tz).to_date.iso8601 } }
      { status: coverage_status(gaps, to - from), missing: missing }
    end

    def coverage_status(gaps, span)
      return "complete" if gaps.empty?

      gaps.sum { |g| g.end - g.begin } >= span ? "none" : "partial"
    end
  end
end
