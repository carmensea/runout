# `source IN ('lastfm', 'runout')` on a varchar column is deparsed one way when created and another
# after pg_dump/pg_restore, so the backup job's schema comparison failed (2026-11-04). Casting to text
# first gives a form that survives a restore unchanged.
class StabiliseLovedTracksSourceCheck < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :loved_tracks, "source IN ('lastfm', 'runout')", name: "loved_tracks_source"
    add_check_constraint :loved_tracks, "source::text IN ('lastfm', 'runout')", name: "loved_tracks_source"
  end
end
