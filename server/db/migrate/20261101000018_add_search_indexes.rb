# Milestone 3 search (Analytics::Search): trigram indexes for partial, case-insensitive and
# misspelled names. pg_trgm ships with PostgreSQL (and Neon). The catalogue's normalised names are
# indexed, and the raw variant strings for plays not matched to the catalogue yet.
class AddSearchIndexes < ActiveRecord::Migration[8.1]
  def change
    enable_extension "pg_trgm"
    add_index :artists, :normalized_name, using: :gin, opclass: :gin_trgm_ops, name: "index_artists_on_normalized_name_trgm"
    add_index :albums, :normalized_title, using: :gin, opclass: :gin_trgm_ops, name: "index_albums_on_normalized_title_trgm"
    add_index :tracks, :normalized_title, using: :gin, opclass: :gin_trgm_ops, name: "index_tracks_on_normalized_title_trgm"
    add_index :name_variants, "lower(artist_name) gin_trgm_ops", using: :gin, name: "index_name_variants_on_artist_name_trgm"
    add_index :name_variants, "lower(track_name) gin_trgm_ops", using: :gin, name: "index_name_variants_on_track_name_trgm"
    add_index :name_variants, "lower(album_name) gin_trgm_ops", using: :gin, name: "index_name_variants_on_album_name_trgm"
  end
end
