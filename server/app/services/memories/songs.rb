module Memories
  # Songs as the diary addresses them: the Overview's track key (`t<id>`, the catalogue track at the
  # end of its merge chain) in and out, the user's own listening for it, and the cover of the album
  # they played it from most. A key with no catalogue row (`m<hash>`: a song the catalogue could not
  # place) cannot carry a memory yet; the caller says so.
  #
  # Every query starts from the user: plays and memories are theirs alone, and a track id is never
  # trusted from outside without resolving it through the catalogue.
  module Songs
    KEY = /\At(\d+)\z/

    module_function

    # The catalogue track a key stands for, at the end of its merge chain; nil for a key that is not
    # a catalogue track or does not exist.
    def resolve(key)
      id = key.to_s[KEY, 1] or return nil
      Track.find_by(id: id)&.resolved
    end

    def key_for(track) = "t#{track.resolved.id}"

    # The user's memories about one song, oldest written first, including those attached to tracks
    # since merged into it.
    def memories_for(user, track)
      user.memories.where(track_id: root_ids_of([ track.id ])).order(:created_at, :id)
    end

    # Every track id whose merge chain ends at one of `roots` (and the roots themselves).
    def root_ids_of(roots)
      ActiveRecord::Base.connection.select_values(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, roots: roots ])) + roots
        SELECT w.id FROM #{Catalogue::Roots.sql('tracks')} w WHERE w.root_id IN (:roots)
      SQL
    end

    # Name, artist and the user's listening for the song: plays in all, first and last, by year in
    # the user's timezone, and the cover of the album they played it from most (verified first,
    # then their inferred one).
    def detail(user, track)
      key = key_for(track)
      tz = user.reporting_timezone.presence || "UTC"
      rows = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, { user: user.id, key: key, tz: tz } ]))
        WITH #{Analytics::Identity.ctes("SELECT DISTINCT name_variant_id FROM scrobbles WHERE user_id = :user AND removed_at IS NULL")}
        SELECT extract(year FROM (s.played_at AT TIME ZONE 'UTC') AT TIME ZONE :tz)::int AS year, count(*), min(s.played_at), max(s.played_at)
          FROM keyed k JOIN scrobbles s ON s.name_variant_id = k.id AND s.user_id = :user AND s.removed_at IS NULL
         WHERE k.track_key = :key
         GROUP BY 1 ORDER BY 1
      SQL
      total = rows.sum { |_, n, _, _| n }
      { id: key, name: track.title, artist: { id: "a#{track.artist.resolved.id}", name: track.artist.resolved.name },
        artworkUrl: artwork(user, [ track.id ])[track.id],
        plays: { total: total, firstPlayedAt: rows.map { |r| r[2] }.min&.utc&.iso8601, lastPlayedAt: rows.map { |r| r[3] }.max&.utc&.iso8601,
                 byYear: rows.map { |year, n, _, _| { year: year, plays: n } } } }
    end

    # Covers for songs, by root track id, in the Overview's order of trust: the catalogue release's
    # cover for the album the user played the song from most, then the user's own inferred cover for
    # that album, then, for a song played with no album name, the user's inferred cover for the song
    # itself. Only this user's plays and inferences count.
    def artwork(user, track_ids)
      return {} if track_ids.empty?

      keys = track_ids.map { |id| "t#{id}" }
      ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, { user: user.id, keys: keys } ])).to_h { |key, url| [ key.delete_prefix("t").to_i, CoverArt::Client.approved(url) ] }.compact
        WITH #{Analytics::Identity.ctes("SELECT DISTINCT name_variant_id FROM scrobbles WHERE user_id = :user AND removed_at IS NULL")},
             played AS (SELECT k.track_key, k.album_key, count(*) AS n FROM keyed k JOIN scrobbles s ON s.name_variant_id = k.id AND s.user_id = :user AND s.removed_at IS NULL
                         WHERE k.track_key IN (:keys) GROUP BY 1, 2),
             best AS (SELECT DISTINCT ON (track_key) track_key, album_key FROM played ORDER BY track_key, (album_key IS NULL), n DESC, album_key),
             inferred AS (SELECT ia.subject_key, COALESCE(a2.thumbnail_250, a2.thumbnail_500) AS url FROM inferred_artworks ia
                            JOIN metadata_artworks a2 ON a2.provider = 'coverartarchive' AND a2.release_id = ia.release_id AND a2.found_on IS NOT NULL
                           WHERE ia.user_id = :user AND ia.status = 'ok')
        SELECT best.track_key, COALESCE(art.thumbnail_250, art.thumbnail_500, by_album.url, by_track.url)
          FROM best
          LEFT JOIN albums al ON best.album_key = 'l' || al.id
          LEFT JOIN metadata_artworks art ON art.provider = 'coverartarchive' AND art.release_id = al.mbid AND art.found_on IS NOT NULL
          LEFT JOIN inferred by_album ON by_album.subject_key = best.album_key
          LEFT JOIN inferred by_track ON by_track.subject_key = best.track_key
      SQL
    end
  end
end
