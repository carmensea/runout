module Analytics
  # The signed-in user's loved songs with their listening (docs/loved-songs.md; src/data/types.ts
  # LovedLibrary). One row per loved song, newest love first. Identity is the same as everywhere else
  # (Analytics::Identity): the catalogue track at the end of its merge chain where the song's variant
  # is linked, otherwise its normalised names. Plays are counted by that identity, so a loved song
  # and its plays agree with the Overview, Search and Time Machine.
  #
  # Dates are labelled by what they are: `lovedAt` is when the song was loved; `firstPlayedAt`,
  # `lastPlayedAt` and `previousPlayedAt` are plays. `link` says how the song reaches the catalogue:
  # `linked`, `review` (fits several tracks, or a possible match is open), or `unlinked`. An unlinked
  # song may still have plays stored under its exact names (`namePlays`), which is not the same as
  # never having been played.
  class Loved
    # A play within this many days counts as recent, for "back in rotation".
    RECENT_DAYS = 90

    def initialize(user:, now: Time.current)
      @user = user
      @now = now
      @tz = user.reporting_timezone.presence || "UTC"
    end

    def call
      loved = LovedTrack.where(user: @user).includes(:name_variant).order(loved_at: :desc, id: :desc).to_a
      return { total: 0, tracks: [], recentDays: RECENT_DAYS, generatedAt: @now.utc.iso8601 } if loved.empty?

      variant_ids = loved.map(&:name_variant_id).uniq
      keyed = rows(<<~SQL, variants: variant_ids).to_h { |id, *rest| [ id, rest ] }
        WITH #{Identity.ctes("SELECT unnest(ARRAY[:variants]::bigint[]) AS name_variant_id")}
        SELECT id, artist_key, artist_name, track_key, track_name FROM keyed
      SQL
      keys = keyed.values.map { |row| row[2] }.uniq
      plays = rows(<<~SQL, user: @user.id, keys: keys, recent: @now - RECENT_DAYS.days, tz: @tz).to_h { |key, *rest| [ key, rest ] }
        WITH #{Identity.ctes("SELECT DISTINCT name_variant_id FROM scrobbles WHERE user_id = :user AND removed_at IS NULL")}
        SELECT k.track_key, count(*), min(s.played_at), max(s.played_at), max(s.played_at) FILTER (WHERE s.played_at < :recent),
               to_char((max(s.played_at) AT TIME ZONE 'UTC') AT TIME ZONE :tz, 'YYYY-MM-DD')
          FROM keyed k JOIN scrobbles s ON s.name_variant_id = k.id AND s.user_id = :user AND s.removed_at IS NULL
         WHERE k.track_key IN (:keys)
         GROUP BY k.track_key
      SQL
      # Plays stored under the same names, whatever their catalogue link: tells "not linked" from "never played".
      name_plays = rows(<<~SQL, user: @user.id, variants: variant_ids).to_h
        SELECT l.id, count(s.id)
          FROM name_variants l
          JOIN name_variants v ON #{Identity::NORMALIZE.call('v.artist_name')} = #{Identity::NORMALIZE.call('l.artist_name')}
                              AND #{Identity::NORMALIZE.call('v.track_name')} = #{Identity::NORMALIZE.call('l.track_name')}
          JOIN scrobbles s ON s.name_variant_id = v.id AND s.user_id = :user AND s.removed_at IS NULL
         WHERE l.id IN (:variants)
         GROUP BY l.id
      SQL
      reviews = CatalogueReview.open.where(name_variant_id: variant_ids, level: "track").pluck(:name_variant_id).to_set

      { total: loved.size, recentDays: RECENT_DAYS, generatedAt: @now.utc.iso8601,
        tracks: loved.map { |l| track(l, keyed.fetch(l.name_variant_id), plays, name_plays.fetch(l.name_variant_id, 0), reviews) } }
    end

    private

    def track(loved, (artist_key, artist_name, track_key, track_name), plays, name_plays, reviews)
      v = loved.name_variant
      count, first, last, previous, last_date = plays[track_key]
      link = if v.track_match == "ambiguous" || reviews.include?(v.id) then "review"
      elsif v.track_id then "linked"
      else "unlinked"
      end
      { id: loved.id, source: loved.source, lovedAt: loved.loved_at.utc.iso8601, unlovedAt: loved.unloved_at&.utc&.iso8601,
        manual: loved.manual, url: loved.source_url,
        artist: { id: artist_key, name: artist_name }, track: { id: track_key, name: track_name },
        asLoved: { artist: v.artist_name, track: v.track_name }, link: link,
        plays: count.to_i, firstPlayedAt: first&.utc&.iso8601, lastPlayedAt: last&.utc&.iso8601, lastPlayedDate: last_date,
        previousPlayedAt: previous&.utc&.iso8601, namePlays: name_plays.to_i }
    end

    def rows(sql, **binds) = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
  end
end
