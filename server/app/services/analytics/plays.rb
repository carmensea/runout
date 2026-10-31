require "base64"

module Analytics
  # Every play in a period, in the order it happened (Time Machine's day view): local date and time,
  # the exact artist, track and album strings that were scrobbled, and the identity keys the
  # Overview uses, for links. Nothing is collapsed: repeated plays and same-second plays are each a
  # row. Removed plays aren't listed.
  #
  # Pages are cut by a cursor on (played_at, seq), the unique slot of a play, so a page boundary
  # inside a second never repeats or skips a play, and later inserts don't shift earlier pages.
  class Plays
    LIMIT = 100
    MAX_LIMIT = 500

    class InvalidCursor < ArgumentError; end

    def initialize(user:, period:, cursor: nil, limit: LIMIT, now: Time.current)
      @user = user
      @period = period
      @tz = user.reporting_timezone.presence || "UTC"
      @after = decode(cursor)
      @limit = limit.to_i.clamp(1, MAX_LIMIT)
      @now = now
    end

    def call
      range = @period.utc_range(@tz)
      from = range.begin || Time.utc(1970)
      to = range.end || Time.utc(9999)
      after_at, after_seq = @after || [ Time.utc(1970), -1 ]
      binds = { user: @user.id, tz: @tz, from: from, to: to, after_at: after_at, after_seq: after_seq, limit: @limit + 1 }
      # Bound, not inlined: a colon in the SQL text (as in HH24:MI) would be read as a bind name.
      formats = { instant_format: 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"', time_format: "HH24:MI:SS" }

      found = rows(<<~SQL, **binds, **formats)
        WITH page AS (
          SELECT played_at, seq, name_variant_id FROM scrobbles
           WHERE user_id = :user AND removed_at IS NULL AND played_at >= :from AND played_at < :to
             AND (played_at, seq) > (:after_at, :after_seq)
           ORDER BY played_at, seq
           LIMIT :limit
        ),
        #{Identity.ctes('SELECT DISTINCT name_variant_id FROM page')}
        SELECT to_char(p.played_at, :instant_format), p.seq,
               to_char((p.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM-DD'),
               to_char((p.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz, :time_format),
               v.artist_name, v.track_name, NULLIF(btrim(v.album_name), ''), k.artist_key, k.track_key, k.album_key
          FROM page p JOIN name_variants v ON v.id = p.name_variant_id JOIN keyed k ON k.id = p.name_variant_id
         ORDER BY p.played_at, p.seq
      SQL
      more = found.size > @limit
      found = found.first(@limit)
      total = rows(<<~SQL, **binds.slice(:user, :from, :to)).first.first
        SELECT count(*) FROM scrobbles WHERE user_id = :user AND removed_at IS NULL AND played_at >= :from AND played_at < :to
      SQL

      { period: @period.serialized, total: total, plays: found.map { |row| play(row) },
        nextCursor: more ? encode(found.last[0], found.last[1]) : nil,
        coverage: @period.all? ? Coverage.new(@user, @tz, now: @now).for(nil, nil) : Coverage.new(@user, @tz, now: @now).for(from, to) }
    end

    private

    def play(row)
      at, seq, date, time, artist, track, album, artist_key, track_key, album_key = row
      { id: "#{at}/#{seq}", playedAt: at, date: date, time: time,
        artist: { id: artist_key, name: artist }, track: { id: track_key, name: track },
        album: album && album_key ? { id: album_key, name: album } : nil }
    end

    # Opaque to clients: the last play's instant (microseconds) and slot.
    def encode(at, seq)
      Base64.urlsafe_encode64("#{(Time.iso8601(at).to_r * 1_000_000).to_i}:#{seq}", padding: false)
    end

    def decode(cursor)
      return nil if cursor.blank?

      micros, seq = Base64.urlsafe_decode64(cursor.to_s).split(":", 2)
      raise InvalidCursor, "unreadable cursor" unless micros&.match?(/\A\d+\z/) && seq&.match?(/\A\d+\z/)

      [ Time.at(Rational(micros.to_i, 1_000_000)).utc, seq.to_i ]
    rescue ArgumentError => e
      raise InvalidCursor, e.message
    end

    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
  end
end
