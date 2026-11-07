module Analytics
  # Everything the Overview's answer for a user depends on, folded into one short string: that
  # user's plays (new ones by count and highest id, removals by their time, restores and
  # corrections by the review rows that carry them), the catalogue their variants resolve through
  # (the variants' links, and the artists, albums and tracks at both ends of their merge chains),
  # the covers on file for those albums' releases and this user's inferred ones, and the genre
  # classifications and artist metadata (rare, global). Scoped to the user's own plays, so another
  # account's listening and covers fetched for albums this user never played change nothing here.
  # A handful of cheap aggregates; the digest changes the moment any of them does, so a cached
  # Overview is never served after a change and the code that writes never has to invalidate.
  module HistoryVersion
    SQL = <<~SQL.freeze
      WITH mine AS (SELECT DISTINCT name_variant_id AS id FROM scrobbles WHERE user_id = :user),
           v AS (SELECT artist_id, album_id, track_id, matched_at FROM name_variants WHERE id IN (SELECT id FROM mine)),
           my_artists AS (SELECT artist_id AS id FROM v WHERE artist_id IS NOT NULL
                          UNION SELECT r.root_id FROM v JOIN #{Catalogue::Roots.sql('artists')} r ON r.id = v.artist_id),
           my_albums AS (SELECT album_id AS id FROM v WHERE album_id IS NOT NULL
                         UNION SELECT r.root_id FROM v JOIN #{Catalogue::Roots.sql('albums')} r ON r.id = v.album_id),
           my_tracks AS (SELECT track_id AS id FROM v WHERE track_id IS NOT NULL
                         UNION SELECT r.root_id FROM v JOIN #{Catalogue::Roots.sql('tracks')} r ON r.id = v.track_id)
      SELECT (SELECT count(*) || '/' || coalesce(max(id)::text, '') || '/' || coalesce(max(removed_at)::text, '') FROM scrobbles WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(updated_at)::text, '') FROM scrobble_removals WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(updated_at)::text, '') FROM scrobble_corrections WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(matched_at)::text, '') FROM v),
             (SELECT coalesce(max(updated_at)::text, '') FROM artists WHERE id IN (SELECT id FROM my_artists)),
             (SELECT coalesce(max(updated_at)::text, '') FROM albums WHERE id IN (SELECT id FROM my_albums)),
             (SELECT coalesce(max(updated_at)::text, '') FROM tracks WHERE id IN (SELECT id FROM my_tracks)),
             (SELECT count(*) || '/' || coalesce(max(fetched_at)::text, '') FROM metadata_artworks
               WHERE release_id IN (SELECT mbid FROM albums WHERE mbid IS NOT NULL AND id IN (SELECT id FROM my_albums))),
             (SELECT count(*) || '/' || coalesce(max(updated_at)::text, '') FROM inferred_artworks WHERE user_id = :user),
             (SELECT coalesce(max(computed_at)::text, '') FROM genre_classifications),
             (SELECT coalesce(max(updated_at)::text, '') FROM metadata_artists)
    SQL

    module_function

    def for(user)
      parts = ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ SQL, { user: user.id } ])).first
      Digest::SHA256.hexdigest(parts.join("|"))[0, 24]
    end
  end
end
