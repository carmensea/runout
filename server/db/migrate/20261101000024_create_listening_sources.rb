# Listening sources, stage 1 (docs/spotify-plan.md §2; docs/long-term-architecture.md §5):
# providers other than Last.fm report plays as observations, and `scrobbles` stays the canonical
# listening event every analytic reads.
#
# - `scrobbles.source`: the provider whose report created the play. Every existing row is a
#   Last.fm play: the constant default is stored in the catalogue (PostgreSQL 11+), so no existing
#   row is rewritten. Last.fm import, reconciliation and counts read only `lastfm` plays from now on.
# - `listening_sources`: a connected provider account per user, with its encrypted credentials and
#   polling state. Last.fm keeps `identities` and `lastfm_connections`.
# - `listening_observations`: one provider report of one play, kept as sent, with its own
#   timestamp and its meaning, the provider's IDs (never mixed with MusicBrainz IDs), and the play it
#   attests: one it created, an existing play from another provider it was matched to, or none
#   while a person decides (`pending_review`).
#
# Additive only.
class CreateListeningSources < ActiveRecord::Migration[8.1]
  def change
    add_column :scrobbles, :source, :string, null: false, default: "lastfm"
    add_check_constraint :scrobbles, "source IN ('lastfm', 'spotify')", name: "scrobbles_source"

    create_table :listening_sources do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false                      # spotify
      t.text :external_account_id, null: false             # the provider's own account ID
      t.text :display_name
      t.string :state, null: false, default: "connected"   # connected, needs_reauth, disconnected
      t.text :credentials                                  # encrypted JSON; never serialised to the API
      t.text :scopes
      t.datetime :connected_at, null: false
      t.datetime :disconnected_at
      t.datetime :paused_at
      t.text :last_error
      t.datetime :last_error_at
      t.timestamps
      t.index [ :provider, :external_account_id ], unique: true
      t.index [ :user_id, :provider ]
      t.check_constraint "provider IN ('spotify')", name: "listening_sources_provider"
      t.check_constraint "state IN ('connected', 'needs_reauth', 'disconnected')", name: "listening_sources_state"
    end

    create_table :listening_observations do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :listening_source, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      t.text :source_event_id, null: false                 # unique per source; see Listening::Event
      t.datetime :reported_at, precision: 6, null: false   # the provider's timestamp, at its precision
      t.text :reported_at_raw, null: false                 # as sent
      t.string :timestamp_kind, null: false                # what reported_at means (Listening::Event::KINDS)
      t.integer :duration_ms
      t.references :name_variant, null: false, foreign_key: true
      t.text :provider_track_id
      t.text :provider_album_id
      t.text :provider_artist_ids, array: true, null: false, default: []
      t.text :isrc                                         # an ISRC, never a MusicBrainz recording ID
      t.jsonb :context
      t.references :scrobble, foreign_key: true            # null only while pending review
      t.string :link_state, null: false                    # created, linked, pending_review
      t.string :linked_by                                  # rule or person
      t.jsonb :match_evidence, null: false, default: {}
      t.datetime :received_at, null: false
      t.datetime :last_seen_at, null: false
      t.integer :times_seen, null: false, default: 1
      t.jsonb :later_values                                # what a later report of the same event said differently
      t.timestamps
      t.index [ :listening_source_id, :source_event_id ], unique: true, name: "index_listening_observations_identity"
      t.index [ :scrobble_id, :provider ], unique: true, where: "scrobble_id IS NOT NULL", name: "index_listening_observations_one_per_provider"
      t.index [ :user_id, :reported_at ]
      t.index [ :user_id, :link_state ]
      t.check_constraint "link_state IN ('created', 'linked', 'pending_review')", name: "listening_observations_link_state"
      t.check_constraint "(link_state = 'pending_review') = (scrobble_id IS NULL)", name: "listening_observations_scrobble"
      t.check_constraint "provider IN ('spotify')", name: "listening_observations_provider"
    end
  end
end
