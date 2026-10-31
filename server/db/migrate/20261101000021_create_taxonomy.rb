# Milestone 4, stage 1: Runout's genre taxonomy (docs/backend-plan.md §6, docs/milestone-4-plan.md §3).
# Broad genres and their subgenres; how provider genre and tag names map onto them; tuning values.
# Seeded from server/db/seeds/taxonomy.yml; rows with origin `manual` are the owner's and are never
# overwritten by seeding. Reference data only: nothing here touches listening history. Additive.
class CreateTaxonomy < ActiveRecord::Migration[8.1]
  def change
    create_table :genres do |t|
      t.string :slug, null: false
      t.string :name, null: false
      t.string :level, null: false # broad or sub
      t.references :parent, foreign_key: { to_table: :genres }
      t.integer :position, null: false, default: 0
      t.string :origin, null: false, default: "seed"
      t.timestamps
      t.index :slug, unique: true
      t.check_constraint "level IN ('broad', 'sub')", name: "genres_level"
      t.check_constraint "(level = 'broad') = (parent_id IS NULL)", name: "genres_parent"
      t.check_constraint "origin IN ('seed', 'manual')", name: "genres_origin"
    end

    # A provider genre or tag name (normalised: lower case, single spaces) and a genre it counts
    # towards, with the share of the name's weight that goes there. One name can map to several genres.
    create_table :tag_genre_mappings do |t|
      t.text :tag, null: false
      t.references :genre, null: false, foreign_key: { on_delete: :cascade }
      t.decimal :weight, precision: 4, scale: 3, null: false
      t.string :origin, null: false, default: "seed"
      t.timestamps
      t.index [ :tag, :genre_id ], unique: true
      t.index :tag
      t.check_constraint "weight > 0 AND weight <= 1", name: "tag_genre_mappings_weight"
      t.check_constraint "origin IN ('seed', 'manual', 'musicbrainz')", name: "tag_genre_mappings_origin"
    end

    create_table :taxonomy_settings, primary_key: :key, id: :string do |t|
      t.decimal :value, precision: 8, scale: 3, null: false
      t.string :origin, null: false, default: "seed"
      t.timestamps
    end
  end
end
