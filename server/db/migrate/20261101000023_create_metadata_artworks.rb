# Milestone 4, stage 4: album artwork from the Cover Art Archive (docs/milestone-4-plan.md §10.4).
# References and provenance only, never image files: thumbnail URLs on the archive's own hosts, for
# a catalogue release. The release's own front cover is preferred; otherwise its release group's,
# found through MusicBrainz's link between the two. Release and release-group IDs are kept in their
# own columns and never confused; nothing is matched by album name. Image rights stay with their
# holders (§10.4), separate from MusicBrainz's metadata licence. Additive.
class CreateMetadataArtworks < ActiveRecord::Migration[8.1]
  def change
    create_table :metadata_artworks do |t|
      t.string :provider, null: false            # coverartarchive
      t.text :release_id, null: false            # the catalogue album's MusicBrainz release ID
      t.text :release_group_id                   # from MusicBrainz, when the release had no cover of its own
      t.string :found_on                         # release or release_group; NULL when there is no cover
      t.text :image_id
      t.text :thumbnail_250
      t.text :thumbnail_500
      t.text :thumbnail_1200
      t.text :source_url, null: false            # the archive page the cover came from
      t.datetime :fetched_at, null: false
      t.timestamps
      t.index [ :provider, :release_id ], unique: true
      t.check_constraint "found_on IS NULL OR found_on IN ('release', 'release_group')", name: "metadata_artworks_found_on"
      t.check_constraint "(found_on = 'release_group') <= (release_group_id IS NOT NULL)", name: "metadata_artworks_group"
    end
  end
end
