# Artist links inferred from names (Catalogue::ArtistInference): a variant without an artist
# MusicBrainz ID, whose normalised name belongs to exactly one identified artist and nothing
# contradicts it, links to that artist. One row per name and artist records the inference and its
# evidence, and whether it was reverted (a reverted inference is never made again). Possible-match
# reviews it settled, and the entities it merged, point at it. Additive, except the artist_match
# constraint gains `inferred`.
class AddCatalogueInferences < ActiveRecord::Migration[8.1]
  LINKED = %w[mbid alias name manual].freeze

  def up
    create_table :catalogue_inferences do |t|
      t.string :level, null: false, default: "artist"
      t.text :normalized_name, null: false
      t.references :into, null: false, foreign_key: { to_table: :artists }
      t.references :from, foreign_key: { to_table: :artists } # the name-only artist merged into `into`, if one existed
      t.string :state, null: false, default: "applied"
      t.integer :rule_version, null: false
      t.jsonb :evidence, null: false, default: {}
      t.datetime :applied_at, null: false
      t.datetime :reverted_at
      t.timestamps
      t.index [ :level, :normalized_name, :into_id ], unique: true
      t.check_constraint "level = 'artist'", name: "catalogue_inferences_level"
      t.check_constraint "state IN ('applied', 'reverted')", name: "catalogue_inferences_state"
      t.check_constraint "(state = 'reverted') = (reverted_at IS NOT NULL)", name: "catalogue_inferences_reverted"
    end

    add_reference :catalogue_reviews, :inference, foreign_key: { to_table: :catalogue_inferences }
    # Set while an entity's merged_into was made by an inference (not a person), so it can be told
    # apart and undone.
    %i[artists albums tracks].each { |table| add_reference table, :inference, foreign_key: { to_table: :catalogue_inferences } }

    replace_artist_constraint(LINKED + %w[inferred])
  end

  def down
    replace_artist_constraint(LINKED)
    %i[artists albums tracks catalogue_reviews].each do |table|
      remove_reference table, :inference, foreign_key: { to_table: :catalogue_inferences }
    end
    drop_table :catalogue_inferences
  end

  private

  def replace_artist_constraint(linked)
    remove_check_constraint :name_variants, name: "name_variants_artist_match"
    add_check_constraint :name_variants,
                         "artist_match IS NULL OR (artist_match IN (#{quoted(linked)}) AND artist_id IS NOT NULL) " \
                         "OR (artist_match IN ('ambiguous', 'unmatched') AND artist_id IS NULL)",
                         name: "name_variants_artist_match"
  end

  def quoted(values) = values.map { |v| connection.quote(v) }.join(", ")
end
