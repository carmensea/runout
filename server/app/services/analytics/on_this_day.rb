module Analytics
  # The same calendar date in the other years of the history (Time Machine's "On this day"): real
  # counts, the most played artists and track, and whether each day is imported. Each day is a local
  # date in the reporting timezone, so a day of 23 or 25 hours is whole. 29 February exists only in
  # leap years; other years are left out, never moved to the 28th or 1 March.
  class OnThisDay
    TOP_ARTISTS = 3

    def initialize(user:, date:, now: Time.current)
      @user = user
      @date = date
      @tz = user.reporting_timezone.presence || "UTC"
      @now = now
    end

    def call
      years = history_years.reject { |y| y == @date.year }.select { |y| Date.valid_date?(y, @date.month, @date.day) }
      zone = Period.zone(@tz)
      days = years.to_h do |y|
        day = Date.new(y, @date.month, @date.day)
        [ y, Period.day_start(zone, day).utc...Period.day_start(zone, day + 1).utc ]
      end
      days.reject! { |_, range| range.begin >= @now }
      top = tops(days)
      coverage = Coverage.new(@user, @tz, now: @now)

      { date: @date.iso8601, leapDay: @date.month == 2 && @date.day == 29,
        years: days.keys.sort.reverse.map do |y|
          found = top.fetch(y, { scrobbles: 0, artists: [], tracks: [] })
          { date: Date.new(y, @date.month, @date.day).iso8601, scrobbles: found[:scrobbles],
            coverage: coverage.status_for(days[y].begin, days[y].end),
            topArtists: found[:artists].first(TOP_ARTISTS), topTrack: found[:tracks].first }
        end }
    end

    private

    # Local years from the first play to the latest one.
    def history_years
      first, last = rows(<<~SQL, user: @user.id, tz: @tz).first
        SELECT extract(year FROM (min(played_at) AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int,
               extract(year FROM (max(played_at) AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int
          FROM scrobbles WHERE user_id = :user AND removed_at IS NULL
      SQL
      first ? (first..last).to_a : []
    end

    # { year => { scrobbles:, artists: [...], tracks: [...] } } for the days with plays.
    def tops(days)
      return {} if days.empty?

      conn = ActiveRecord::Base.connection
      values = days.map { |y, r| "(#{Integer(y)}, #{conn.quote(r.begin)}::timestamp, #{conn.quote(r.end)}::timestamp)" }.join(", ")
      found = rows(<<~SQL, user: @user.id)
        WITH days(y, f, t) AS (VALUES #{values}),
        plays AS (
          SELECT d.y, s.name_variant_id FROM days d
            JOIN scrobbles s ON s.user_id = :user AND s.removed_at IS NULL AND s.played_at >= d.f AND s.played_at < d.t
        ),
        #{Identity.ctes('SELECT DISTINCT name_variant_id FROM plays')}
        SELECT 'artist', p.y, k.artist_key, mode() WITHIN GROUP (ORDER BY k.artist_name), NULL, count(*)
          FROM plays p JOIN keyed k ON k.id = p.name_variant_id GROUP BY p.y, k.artist_key
        UNION ALL
        SELECT 'track', p.y, k.track_key, mode() WITHIN GROUP (ORDER BY k.track_name), mode() WITHIN GROUP (ORDER BY k.artist_name), count(*)
          FROM plays p JOIN keyed k ON k.id = p.name_variant_id GROUP BY p.y, k.track_key
      SQL
      found.group_by { |_, y, *| y }.transform_values do |list|
        artists, tracks = list.partition { |kind, *| kind == "artist" }
        order = ->(entries) { entries.sort_by { |*, name, _, n| [ -n, name.to_s.downcase ] } }
        { scrobbles: artists.sum(&:last),
          artists: order.call(artists).map { |_, _, id, name, _, n| { id: id, name: name, scrobbles: n } },
          tracks: order.call(tracks).map { |_, _, id, name, artist, n| { id: id, name: name, artist: artist, scrobbles: n } } }
      end
    end

    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
  end
end
