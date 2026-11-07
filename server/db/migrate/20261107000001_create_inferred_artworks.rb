# Artwork inferred for one user's albums and tracks that have no catalogue release id, from
# ListenBrainz's MBID mapping of that user's own listens (docs/milestone-4-plan.md §14). One row per
# user and Overview key: the release every observation agreed on, what MusicBrainz said about it,
# and the outcome. The catalogue is untouched; the cover itself is the release's row in
# metadata_artworks. Deleted with the user.
class CreateInferredArtworks < ActiveRecord::Migration[8.1]
  def change
    create_table :inferred_artworks do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :subject_key, null: false
      t.string :provider, null: false, default: "listenbrainz_mapping"
      t.text :release_id, null: false
      t.text :recording_id
      t.integer :observations, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.jsonb :evidence, null: false, default: {}
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at
      t.datetime :checked_at
      t.text :last_error
      t.timestamps
    end
    add_index :inferred_artworks, %i[user_id subject_key], unique: true
    add_check_constraint :inferred_artworks, "status::text IN ('pending', 'ok', 'none', 'mismatch', 'failed')", name: "inferred_artworks_status"
    add_check_constraint :inferred_artworks, "provider::text IN ('listenbrainz_mapping')", name: "inferred_artworks_provider"
  end
end
