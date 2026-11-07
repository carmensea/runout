module Analytics
  # Everything the Overview's answer for a user depends on, folded into one short string: that
  # user's plays (new ones by count and highest id, removals by their time, restores and
  # corrections by the review rows that carry them), the catalogue every variant resolves through
  # (links, merges), the covers on file and this user's inferred ones, the genre classifications and
  # artist metadata. A handful of cheap aggregates; the digest changes the moment any of them does,
  # so a cached Overview is never served after a change and the code that writes never has to
  # invalidate anything.
  module HistoryVersion
    SQL = <<~SQL.freeze
      SELECT (SELECT count(*) || '/' || coalesce(max(id)::text, '') || '/' || coalesce(max(removed_at)::text, '') FROM scrobbles WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(updated_at)::text, '') FROM scrobble_removals WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(updated_at)::text, '') FROM scrobble_corrections WHERE user_id = :user),
             (SELECT count(*) || '/' || coalesce(max(matched_at)::text, '') FROM name_variants),
             (SELECT coalesce(max(updated_at)::text, '') FROM artists),
             (SELECT coalesce(max(updated_at)::text, '') FROM albums),
             (SELECT coalesce(max(updated_at)::text, '') FROM tracks),
             (SELECT count(*) || '/' || coalesce(max(fetched_at)::text, '') FROM metadata_artworks),
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
