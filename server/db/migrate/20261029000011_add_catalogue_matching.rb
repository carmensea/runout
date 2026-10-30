# Stage 2.5: canonical matching state (docs/milestone-2-plan.md §6.4). Additive only: name variants
# keep their exact strings; matching records, per level, how each link was made, and ambiguous or
# uncertain cases are kept for review instead of being guessed.
class AddCatalogueMatching < ActiveRecord::Migration[8.1]
  LINKED = %w[mbid alias name manual].freeze

  def change
    change_table :name_variants, bulk: true do |t|
      t.string :artist_match
      t.string :album_match
      t.string :track_match
      t.integer :match_version # matching rules that produced the links; older or NULL is re-matched
    end
    add_index :name_variants, :match_version

    { artist: %w[ambiguous unmatched], album: %w[ambiguous unmatched none], track: %w[ambiguous unmatched] }.each do |level, unlinked|
      add_check_constraint :name_variants,
                           "#{level}_match IS NULL OR (#{level}_match IN (#{quoted(LINKED)}) AND #{level}_id IS NOT NULL) " \
                           "OR (#{level}_match IN (#{quoted(unlinked)}) AND #{level}_id IS NULL)",
                           name: "name_variants_#{level}_match"
    end

    # Alternative names that identify one artist. Only curated sources: a shared normalised name
    # alone never links a variant to an artist.
    create_table :artist_aliases do |t|
      t.references :artist, null: false, foreign_key: { on_delete: :cascade }
      t.text :name, null: false
      t.text :normalized_name, null: false
      t.string :source, null: false
      t.datetime :created_at, null: false
      t.index [ :artist_id, :normalized_name ], unique: true
      t.index :normalized_name
      t.check_constraint "source IN ('manual', 'musicbrainz')", name: "artist_aliases_source"
    end

    # Matching questions for a person: a variant that fits several entities (`ambiguous`), or one
    # linked to a name-only entity that may be the same as an identified one (`possible_match`).
    create_table :catalogue_reviews do |t|
      t.references :name_variant, null: false, foreign_key: { on_delete: :cascade }
      t.string :level, null: false
      t.string :kind, null: false
      t.bigint :candidate_ids, array: true, null: false, default: []
      t.string :state, null: false, default: "open"
      t.bigint :chosen_id
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :decided_at
      t.timestamps
      t.index [ :name_variant_id, :level, :kind ], unique: true, where: "state = 'open'", name: "index_catalogue_reviews_one_open"
      t.index :state
      t.check_constraint "level IN ('artist', 'album', 'track')", name: "catalogue_reviews_level"
      t.check_constraint "kind IN ('ambiguous', 'possible_match')", name: "catalogue_reviews_kind"
      t.check_constraint "state IN ('open', 'resolved', 'dismissed', 'superseded')", name: "catalogue_reviews_state"
    end
  end

  private

  def quoted(values) = values.map { |v| "'#{v}'" }.join(", ")
end
