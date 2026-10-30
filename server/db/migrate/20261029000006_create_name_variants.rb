# The exact strings Last.fm sent, stored once per distinct combination and never modified.
# Scrobbles point here, not at catalogue rows, so improving catalogue links later re-attributes
# history without rewriting a single scrobble. docs/milestone-2-plan.md §6.3.
class CreateNameVariants < ActiveRecord::Migration[8.1]
  def change
    create_table :name_variants do |t|
      # SHA-256 of the exact tuple below (see NameVariant.hash_for).
      t.binary :variant_hash, null: false
      t.text :artist_name, null: false
      t.text :track_name, null: false
      t.text :album_name, null: false, default: "" # "" means Last.fm sent no album
      t.text :artist_mbid
      t.text :track_mbid
      t.text :album_mbid

      # Catalogue links: nullable until resolved, replaceable at any time.
      t.references :artist, foreign_key: true
      t.references :album, foreign_key: true
      t.references :track, foreign_key: true
      t.string :match_method # mbid | normalized_name | manual
      t.datetime :matched_at

      t.datetime :created_at, null: false
    end
    add_index :name_variants, :variant_hash, unique: true
    add_check_constraint :name_variants, "octet_length(variant_hash) = 32", name: "name_variants_hash_length"
    add_check_constraint :name_variants, "match_method IS NULL OR match_method IN ('mbid', 'normalized_name', 'manual')",
                         name: "name_variants_match_method"
  end
end
