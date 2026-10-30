# Shared music catalogue (no user data). docs/milestone-2-plan.md §6.3 and §6.4.
#
# - MusicBrainz IDs are unique when present. Names are indexed but never unique, so the schema
#   never forces two distinct artists or recordings together just because their names match.
# - `merged_into_id` lets later, better matching redirect one entity to another without touching
#   name variants or scrobbles (no re-import).
class CreateMusicCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :artists do |t|
      t.text :name, null: false
      t.text :normalized_name, null: false
      t.text :mbid
      t.references :merged_into, foreign_key: { to_table: :artists }
      t.timestamps
    end
    add_index :artists, :mbid, unique: true, where: "mbid IS NOT NULL"
    add_index :artists, :normalized_name

    create_table :albums do |t|
      t.references :artist, null: false, foreign_key: true
      t.text :title, null: false
      t.text :normalized_title, null: false
      t.text :mbid
      t.references :merged_into, foreign_key: { to_table: :albums }
      t.timestamps
    end
    add_index :albums, :mbid, unique: true, where: "mbid IS NOT NULL"
    add_index :albums, [ :artist_id, :normalized_title ]

    create_table :tracks do |t|
      t.references :artist, null: false, foreign_key: true
      t.text :title, null: false
      t.text :normalized_title, null: false
      t.text :mbid
      t.references :merged_into, foreign_key: { to_table: :tracks }
      t.timestamps
    end
    add_index :tracks, :mbid, unique: true, where: "mbid IS NOT NULL"
    add_index :tracks, [ :artist_id, :normalized_title ]
  end
end
