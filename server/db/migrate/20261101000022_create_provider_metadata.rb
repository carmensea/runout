# Milestone 4, stage 2: metadata about catalogue entities from outside providers (MusicBrainz first),
# kept apart from the owner's listening history (docs/milestone-4-plan.md §2, §5, §10). Rows are
# keyed by the provider's own ID, never by a scrobble, and record provider, licence, source and
# retrieval time. Classifications derived from them live in their own table and can be rebuilt at
# any time. The owner's corrections (metadata_overrides) are never written by enrichment. Additive.
class CreateProviderMetadata < ActiveRecord::Migration[8.1]
  def change
    # What MusicBrainz says about an artist, as fetched. Core fields are CC0; genres and tags
    # (metadata_tags) are MusicBrainz "supplementary data", CC BY-NC-SA 3.0.
    create_table :metadata_artists do |t|
      t.string :provider, null: false
      t.text :provider_id, null: false            # the ID Runout asked for (the catalogue's MBID)
      t.text :canonical_id                        # the ID the provider answered with, when it differs (merged upstream)
      t.text :name
      t.text :sort_name
      t.text :disambiguation
      t.string :artist_type                       # Person, Group, Orchestra, Choir, Character, Other, or NULL when not listed
      t.string :gender                            # Male, Female, Non-binary, Other, Not applicable, or NULL when not listed
      t.text :area_name
      t.string :area_code                         # ISO 3166-1 code of the area, when the provider gives one
      t.string :begin_date
      t.string :end_date
      t.boolean :ended
      t.string :core_license, null: false
      t.text :source_url, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
      t.index [ :provider, :provider_id ], unique: true
    end

    # Genres and tags with their vote counts, exactly as the provider names them.
    create_table :metadata_tags do |t|
      t.string :provider, null: false
      t.string :entity_kind, null: false          # artist now; release_group or recording later
      t.text :provider_id, null: false
      t.string :kind, null: false                 # genre (the provider's curated list) or tag (free-form)
      t.text :name, null: false
      t.integer :votes, null: false
      t.string :license, null: false
      t.datetime :fetched_at, null: false
      t.timestamps
      t.index [ :provider, :entity_kind, :provider_id, :kind, :name ], unique: true, name: "index_metadata_tags_identity"
      t.index :name
      t.check_constraint "kind IN ('genre', 'tag')", name: "metadata_tags_kind"
    end

    # The enrichment queue and each entity's state: priority (plays), due time, attempts, outcome.
    # `not_found` and `invalid` are negative results, cached until `next_attempt_at`.
    create_table :metadata_targets do |t|
      t.string :provider, null: false
      t.string :entity_kind, null: false
      t.text :provider_id, null: false
      t.integer :priority, null: false, default: 0
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.datetime :next_attempt_at, null: false
      t.datetime :last_attempt_at
      t.datetime :last_success_at
      t.integer :last_http_status
      t.text :last_error
      t.timestamps
      t.index [ :provider, :entity_kind, :provider_id ], unique: true, name: "index_metadata_targets_identity"
      t.index [ :status, :next_attempt_at, :priority ], name: "index_metadata_targets_due"
      t.check_constraint "status IN ('pending', 'ok', 'not_found', 'invalid', 'failed')", name: "metadata_targets_status"
    end

    # Every request and what came of it: the refresh history.
    create_table :metadata_fetches do |t|
      t.string :provider, null: false
      t.string :entity_kind, null: false
      t.text :provider_id, null: false
      t.text :url, null: false
      t.integer :http_status
      t.string :outcome, null: false              # ok, not_found, invalid, rate_limited, error
      t.integer :duration_ms
      t.jsonb :changed_values, null: false, default: {} # what changed compared with the previous fetch
      t.text :error
      t.datetime :requested_at, null: false
      t.index [ :provider, :entity_kind, :provider_id ], name: "index_metadata_fetches_entity"
    end

    # The owner's corrections, which win over provider values and are never touched by enrichment.
    create_table :metadata_overrides do |t|
      t.string :entity_kind, null: false
      t.text :provider_id, null: false            # MBID of the entity corrected
      t.string :field, null: false                # genres, artist_type or gender
      t.jsonb :value, null: false
      t.text :note
      t.timestamps
      t.index [ :entity_kind, :provider_id, :field ], unique: true, name: "index_metadata_overrides_identity"
      t.check_constraint "field IN ('genres', 'artist_type', 'gender')", name: "metadata_overrides_field"
    end

    # Derived: each entity's genre shares (Genres::Classifier), rebuilt when metadata, overrides or the
    # taxonomy change. `level` says what was classified, so release-group or recording genres can
    # refine artist genres later.
    create_table :genre_classifications do |t|
      t.string :level, null: false                # artist
      t.text :provider_id, null: false
      t.string :basis, null: false                # musicbrainz, override, or none (no metadata yet)
      t.boolean :unclassified, null: false
      t.jsonb :broad, null: false, default: {}
      t.jsonb :sub, null: false, default: {}
      t.text :present, array: true, null: false, default: []
      t.text :signals_used, array: true, null: false, default: []
      t.datetime :computed_at, null: false
      t.index [ :level, :provider_id ], unique: true
      t.check_constraint "level IN ('artist', 'release_group', 'recording')", name: "genre_classifications_level"
    end
  end
end
