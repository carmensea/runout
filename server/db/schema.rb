# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_10_29_000009) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"

  create_table "albums", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.text "title", null: false
    t.text "normalized_title", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "normalized_title"], name: "index_albums_on_artist_id_and_normalized_title"
    t.index ["artist_id"], name: "index_albums_on_artist_id"
    t.index ["mbid"], name: "index_albums_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_albums_on_merged_into_id"
  end

  create_table "api_request_slots", primary_key: "key", id: :string, force: :cascade do |t|
    t.timestamptz "next_slot_at", null: false
    t.timestamptz "updated_at", null: false
  end

  create_table "artists", force: :cascade do |t|
    t.text "name", null: false
    t.text "normalized_name", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["mbid"], name: "index_artists_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_artists_on_merged_into_id"
    t.index ["normalized_name"], name: "index_artists_on_normalized_name"
  end

  create_table "identities", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "provider", null: false
    t.string "uid", null: false
    t.string "username"
    t.string "profile_url"
    t.datetime "registered_at"
    t.text "credentials"
    t.datetime "last_authenticated_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "uid"], name: "index_identities_on_provider_and_uid", unique: true
    t.index ["user_id", "provider"], name: "index_identities_on_user_id_and_provider", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
  end

  create_table "import_runs", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "kind", null: false
    t.string "state", default: "planning", null: false
    t.integer "expected_scrobbles"
    t.integer "committed_scrobbles", default: 0, null: false
    t.datetime "started_at"
    t.datetime "finished_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "created_at"], name: "index_import_runs_on_user_id_and_created_at"
    t.index ["user_id"], name: "index_import_runs_on_user_id"
    t.check_constraint "kind::text = ANY (ARRAY['full'::character varying, 'sync'::character varying, 'catch_up'::character varying, 'reconcile'::character varying]::text[])", name: "import_runs_kind"
    t.check_constraint "state::text = ANY (ARRAY['planning'::character varying, 'running'::character varying, 'completed'::character varying, 'failed'::character varying, 'cancelled'::character varying]::text[])", name: "import_runs_state"
  end

  create_table "import_window_fetches", force: :cascade do |t|
    t.bigint "import_window_id", null: false
    t.integer "attempt", null: false
    t.string "outcome", default: "in_progress", null: false
    t.integer "expected_total"
    t.integer "row_count", default: 0, null: false
    t.integer "malformed_count", default: 0, null: false
    t.integer "http_status"
    t.integer "lastfm_error"
    t.integer "error_page"
    t.text "error_message"
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_window_id", "attempt"], name: "index_import_window_fetches_on_import_window_id_and_attempt", unique: true
    t.index ["import_window_id"], name: "index_import_window_fetches_on_import_window_id"
    t.check_constraint "outcome::text = ANY (ARRAY['in_progress'::character varying, 'validated'::character varying, 'mismatch'::character varying, 'failed'::character varying]::text[])", name: "import_window_fetches_outcome"
  end

  create_table "import_window_rows", force: :cascade do |t|
    t.bigint "import_window_fetch_id", null: false
    t.datetime "played_at", null: false
    t.integer "position", null: false
    t.integer "occurrence", null: false
    t.binary "variant_hash", null: false
    t.text "artist_name", null: false
    t.text "track_name", null: false
    t.text "album_name", default: "", null: false
    t.text "artist_mbid"
    t.text "track_mbid"
    t.text "album_mbid"
    t.index ["import_window_fetch_id", "played_at", "position"], name: "index_import_window_rows_identity", unique: true
    t.index ["import_window_fetch_id", "played_at", "variant_hash", "occurrence"], name: "index_import_window_rows_occurrence", unique: true
  end

  create_table "import_windows", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "import_run_id"
    t.bigint "parent_window_id"
    t.datetime "window_from", null: false
    t.datetime "window_to", null: false
    t.string "state", default: "pending", null: false
    t.integer "expected_total"
    t.integer "fetched_count"
    t.integer "malformed_count", default: 0, null: false
    t.integer "attempts", default: 0, null: false
    t.uuid "claim_token"
    t.datetime "lease_expires_at"
    t.integer "last_http_status"
    t.integer "last_lastfm_error"
    t.integer "last_error_page"
    t.text "last_error_message"
    t.datetime "validated_at"
    t.datetime "committed_at"
    t.integer "lock_version", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["import_run_id"], name: "index_import_windows_on_import_run_id"
    t.index ["parent_window_id"], name: "index_import_windows_on_parent_window_id"
    t.index ["user_id", "state"], name: "index_import_windows_on_user_id_and_state"
    t.index ["user_id", "window_from", "window_to"], name: "index_import_windows_on_user_id_and_window_from_and_window_to", unique: true
    t.index ["user_id"], name: "index_import_windows_on_user_id"
    t.check_constraint "(state::text <> ALL (ARRAY['validated'::character varying, 'committing'::character varying, 'committed'::character varying]::text[])) OR validated_at IS NOT NULL", name: "import_windows_validated_at"
    t.check_constraint "state::text <> 'committed'::text OR committed_at IS NOT NULL", name: "import_windows_committed_at"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'fetching'::character varying, 'validating'::character varying, 'validated'::character varying, 'committing'::character varying, 'committed'::character varying, 'failed'::character varying, 'needs_review'::character varying, 'split'::character varying]::text[])", name: "import_windows_state"
    t.check_constraint "window_from < window_to", name: "import_windows_range"
    t.exclusion_constraint "user_id WITH =, tsrange(window_from, window_to, '[)'::text) WITH &&", where: "(state)::text <> 'split'::text", using: :gist, name: "import_windows_no_overlap"
  end

  create_table "lastfm_connections", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "identity_id", null: false
    t.string "history_state", default: "not_started", null: false
    t.datetime "last_synced_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["identity_id"], name: "index_lastfm_connections_on_identity_id", unique: true
    t.index ["user_id"], name: "index_lastfm_connections_on_user_id", unique: true
    t.check_constraint "history_state::text = ANY (ARRAY['not_started'::character varying, 'importing'::character varying, 'imported'::character varying, 'failed'::character varying]::text[])", name: "lastfm_connections_history_state_check"
  end

  create_table "name_variants", force: :cascade do |t|
    t.binary "variant_hash", null: false
    t.text "artist_name", null: false
    t.text "track_name", null: false
    t.text "album_name", default: "", null: false
    t.text "artist_mbid"
    t.text "track_mbid"
    t.text "album_mbid"
    t.bigint "artist_id"
    t.bigint "album_id"
    t.bigint "track_id"
    t.string "match_method"
    t.datetime "matched_at"
    t.datetime "created_at", null: false
    t.index ["album_id"], name: "index_name_variants_on_album_id"
    t.index ["artist_id"], name: "index_name_variants_on_artist_id"
    t.index ["track_id"], name: "index_name_variants_on_track_id"
    t.index ["variant_hash"], name: "index_name_variants_on_variant_hash", unique: true
    t.check_constraint "match_method IS NULL OR (match_method::text = ANY (ARRAY['mbid'::character varying, 'normalized_name'::character varying, 'manual'::character varying]::text[]))", name: "name_variants_match_method"
    t.check_constraint "octet_length(variant_hash) = 32", name: "name_variants_hash_length"
  end

  create_table "scrobble_corrections", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "scrobble_id", null: false
    t.bigint "from_variant_id", null: false
    t.bigint "to_variant_id", null: false
    t.bigint "import_window_fetch_id"
    t.string "state", null: false
    t.string "reason", null: false
    t.datetime "decided_at"
    t.uuid "decided_by_id"
    t.text "decision_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_by_id"], name: "index_scrobble_corrections_on_decided_by_id"
    t.index ["from_variant_id"], name: "index_scrobble_corrections_on_from_variant_id"
    t.index ["import_window_fetch_id"], name: "index_scrobble_corrections_on_import_window_fetch_id"
    t.index ["scrobble_id"], name: "index_scrobble_corrections_on_scrobble_id"
    t.index ["scrobble_id"], name: "index_scrobble_corrections_one_open", unique: true, where: "((state)::text = 'pending_review'::text)"
    t.index ["to_variant_id"], name: "index_scrobble_corrections_on_to_variant_id"
    t.index ["user_id"], name: "index_scrobble_corrections_on_user_id"
    t.check_constraint "from_variant_id <> to_variant_id", name: "scrobble_corrections_changes_something"
    t.check_constraint "state::text = 'pending_review'::text OR decided_at IS NOT NULL", name: "scrobble_corrections_decided"
    t.check_constraint "state::text = ANY (ARRAY['applied'::character varying, 'pending_review'::character varying, 'dismissed'::character varying]::text[])", name: "scrobble_corrections_state"
  end

  create_table "scrobble_removals", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "scrobble_id", null: false
    t.bigint "first_missing_fetch_id", null: false
    t.bigint "confirming_fetch_id"
    t.string "state", default: "observed", null: false
    t.datetime "decided_at"
    t.uuid "decided_by_id"
    t.text "decision_note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["confirming_fetch_id"], name: "index_scrobble_removals_on_confirming_fetch_id"
    t.index ["decided_by_id"], name: "index_scrobble_removals_on_decided_by_id"
    t.index ["first_missing_fetch_id"], name: "index_scrobble_removals_on_first_missing_fetch_id"
    t.index ["scrobble_id"], name: "index_scrobble_removals_on_scrobble_id"
    t.index ["scrobble_id"], name: "index_scrobble_removals_one_open", unique: true, where: "((state)::text = ANY ((ARRAY['observed'::character varying, 'pending_review'::character varying])::text[]))"
    t.index ["user_id"], name: "index_scrobble_removals_on_user_id"
    t.check_constraint "(state::text <> ALL (ARRAY['approved'::character varying, 'dismissed'::character varying]::text[])) OR decided_at IS NOT NULL", name: "scrobble_removals_decided"
    t.check_constraint "state::text <> 'pending_review'::text OR confirming_fetch_id IS NOT NULL", name: "scrobble_removals_two_reads"
    t.check_constraint "state::text = ANY (ARRAY['observed'::character varying, 'pending_review'::character varying, 'approved'::character varying, 'dismissed'::character varying, 'restored'::character varying]::text[])", name: "scrobble_removals_state"
  end

  create_table "scrobbles", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.datetime "played_at", null: false
    t.integer "seq", limit: 2, default: 0, null: false
    t.bigint "name_variant_id", null: false
    t.datetime "removed_at"
    t.bigint "first_seen_fetch_id"
    t.datetime "created_at", null: false
    t.index ["name_variant_id"], name: "index_scrobbles_on_name_variant_id"
    t.index ["user_id", "played_at", "seq"], name: "index_scrobbles_identity", unique: true
    t.check_constraint "seq >= 0", name: "scrobbles_seq_non_negative"
  end

  create_table "sessions", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "last_seen_at", null: false
    t.string "ip_address"
    t.string "user_agent"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tracks", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.text "title", null: false
    t.text "normalized_title", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["artist_id", "normalized_title"], name: "index_tracks_on_artist_id_and_normalized_title"
    t.index ["artist_id"], name: "index_tracks_on_artist_id"
    t.index ["mbid"], name: "index_tracks_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_tracks_on_merged_into_id"
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "display_name", null: false
    t.string "reporting_timezone", default: "UTC", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  add_foreign_key "albums", "albums", column: "merged_into_id"
  add_foreign_key "albums", "artists"
  add_foreign_key "artists", "artists", column: "merged_into_id"
  add_foreign_key "identities", "users", on_delete: :cascade
  add_foreign_key "import_runs", "users", on_delete: :cascade
  add_foreign_key "import_window_fetches", "import_windows", on_delete: :cascade
  add_foreign_key "import_window_rows", "import_window_fetches", on_delete: :cascade
  add_foreign_key "import_windows", "import_runs", on_delete: :nullify
  add_foreign_key "import_windows", "import_windows", column: "parent_window_id", on_delete: :cascade
  add_foreign_key "import_windows", "users", on_delete: :cascade
  add_foreign_key "lastfm_connections", "identities", on_delete: :cascade
  add_foreign_key "lastfm_connections", "users", on_delete: :cascade
  add_foreign_key "name_variants", "albums"
  add_foreign_key "name_variants", "artists"
  add_foreign_key "name_variants", "tracks"
  add_foreign_key "scrobble_corrections", "import_window_fetches", on_delete: :nullify
  add_foreign_key "scrobble_corrections", "name_variants", column: "from_variant_id"
  add_foreign_key "scrobble_corrections", "name_variants", column: "to_variant_id"
  add_foreign_key "scrobble_corrections", "scrobbles", on_delete: :cascade
  add_foreign_key "scrobble_corrections", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "scrobble_corrections", "users", on_delete: :cascade
  add_foreign_key "scrobble_removals", "import_window_fetches", column: "confirming_fetch_id"
  add_foreign_key "scrobble_removals", "import_window_fetches", column: "first_missing_fetch_id"
  add_foreign_key "scrobble_removals", "scrobbles", on_delete: :cascade
  add_foreign_key "scrobble_removals", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "scrobble_removals", "users", on_delete: :cascade
  add_foreign_key "scrobbles", "import_window_fetches", column: "first_seen_fetch_id", on_delete: :nullify
  add_foreign_key "scrobbles", "name_variants"
  add_foreign_key "scrobbles", "users", on_delete: :cascade
  add_foreign_key "sessions", "users", on_delete: :cascade
  add_foreign_key "tracks", "artists"
  add_foreign_key "tracks", "tracks", column: "merged_into_id"
end
