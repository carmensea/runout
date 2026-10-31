# MusicBrainz IDs that Last.fm reported inconsistently for the same plays (docs/milestone-2-plan.md
# §4.3): two reads of a window with the same plays, at the same times with the same strings, but
# different IDs. The IDs are enrichment, not the identity of a play, so such plays are stored
# without the disputed ID, and the candidates are kept here. Matching ignores an ID at that level for
# those exact strings, so every play of the song resolves the same way. Strings and candidate IDs
# only; no API responses. Additive only.
class CreateMbidDisputes < ActiveRecord::Migration[8.1]
  def change
    create_table :mbid_disputes do |t|
      t.binary :strings_hash, null: false # SHA-256 over [level, artist_name, title], as NameVariant hashes its strings
      t.string :level, null: false
      t.text :artist_name, null: false
      t.text :title # the album or track name; NULL for an artist
      t.text :candidate_mbids, array: true, null: false, default: []
      t.integer :occurrences, null: false, default: 0 # disputed plays seen, summed over validations
      t.references :first_import_window, foreign_key: { to_table: :import_windows, on_delete: :nullify }
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index :strings_hash, unique: true
      t.check_constraint "level IN ('artist', 'album', 'track')", name: "mbid_disputes_level"
      t.check_constraint "(level = 'artist') = (title IS NULL)", name: "mbid_disputes_title"
    end
  end
end
