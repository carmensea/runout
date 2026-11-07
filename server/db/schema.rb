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

ActiveRecord::Schema[8.1].define(version: 2026_11_07_000003) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "btree_gist"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "albums", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.text "title", null: false
    t.text "normalized_title", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "inference_id"
    t.index ["artist_id", "normalized_title"], name: "index_albums_on_artist_id_and_normalized_title"
    t.index ["artist_id"], name: "index_albums_on_artist_id"
    t.index ["inference_id"], name: "index_albums_on_inference_id"
    t.index ["mbid"], name: "index_albums_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_albums_on_merged_into_id"
    t.index ["normalized_title"], name: "index_albums_on_normalized_title_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "api_request_slots", primary_key: "key", id: :string, force: :cascade do |t|
    t.timestamptz "next_slot_at", null: false
    t.timestamptz "updated_at", null: false
  end

  create_table "artist_aliases", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.text "name", null: false
    t.text "normalized_name", null: false
    t.string "source", null: false
    t.datetime "created_at", null: false
    t.index ["artist_id", "normalized_name"], name: "index_artist_aliases_on_artist_id_and_normalized_name", unique: true
    t.index ["artist_id"], name: "index_artist_aliases_on_artist_id"
    t.index ["normalized_name"], name: "index_artist_aliases_on_normalized_name"
    t.check_constraint "source::text = ANY (ARRAY['manual'::character varying, 'musicbrainz'::character varying]::text[])", name: "artist_aliases_source"
  end

  create_table "artists", force: :cascade do |t|
    t.text "name", null: false
    t.text "normalized_name", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "inference_id"
    t.index ["inference_id"], name: "index_artists_on_inference_id"
    t.index ["mbid"], name: "index_artists_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_artists_on_merged_into_id"
    t.index ["normalized_name"], name: "index_artists_on_normalized_name"
    t.index ["normalized_name"], name: "index_artists_on_normalized_name_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "catalogue_inferences", force: :cascade do |t|
    t.string "level", default: "artist", null: false
    t.text "normalized_name", null: false
    t.bigint "into_id", null: false
    t.bigint "from_id"
    t.string "state", default: "applied", null: false
    t.integer "rule_version", null: false
    t.jsonb "evidence", default: {}, null: false
    t.datetime "applied_at", null: false
    t.datetime "reverted_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["from_id"], name: "index_catalogue_inferences_on_from_id"
    t.index ["into_id"], name: "index_catalogue_inferences_on_into_id"
    t.index ["level", "normalized_name", "into_id"], name: "idx_on_level_normalized_name_into_id_58a09f59de", unique: true
    t.check_constraint "(state::text = 'reverted'::text) = (reverted_at IS NOT NULL)", name: "catalogue_inferences_reverted"
    t.check_constraint "level::text = 'artist'::text", name: "catalogue_inferences_level"
    t.check_constraint "state::text = ANY (ARRAY['applied'::character varying, 'reverted'::character varying]::text[])", name: "catalogue_inferences_state"
  end

  create_table "catalogue_reviews", force: :cascade do |t|
    t.bigint "name_variant_id", null: false
    t.string "level", null: false
    t.string "kind", null: false
    t.bigint "candidate_ids", default: [], null: false, array: true
    t.string "state", default: "open", null: false
    t.bigint "chosen_id"
    t.uuid "decided_by_id"
    t.datetime "decided_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "inference_id"
    t.index ["decided_by_id"], name: "index_catalogue_reviews_on_decided_by_id"
    t.index ["inference_id"], name: "index_catalogue_reviews_on_inference_id"
    t.index ["name_variant_id", "level", "kind"], name: "index_catalogue_reviews_one_open", unique: true, where: "((state)::text = 'open'::text)"
    t.index ["name_variant_id"], name: "index_catalogue_reviews_on_name_variant_id"
    t.index ["state"], name: "index_catalogue_reviews_on_state"
    t.check_constraint "kind::text = ANY (ARRAY['ambiguous'::character varying, 'possible_match'::character varying]::text[])", name: "catalogue_reviews_kind"
    t.check_constraint "level::text = ANY (ARRAY['artist'::character varying, 'album'::character varying, 'track'::character varying]::text[])", name: "catalogue_reviews_level"
    t.check_constraint "state::text = ANY (ARRAY['open'::character varying, 'resolved'::character varying, 'dismissed'::character varying, 'superseded'::character varying]::text[])", name: "catalogue_reviews_state"
  end

  create_table "genre_classifications", force: :cascade do |t|
    t.string "level", null: false
    t.text "provider_id", null: false
    t.string "basis", null: false
    t.boolean "unclassified", null: false
    t.jsonb "broad", default: {}, null: false
    t.jsonb "sub", default: {}, null: false
    t.text "present", default: [], null: false, array: true
    t.text "signals_used", default: [], null: false, array: true
    t.datetime "computed_at", null: false
    t.index ["level", "provider_id"], name: "index_genre_classifications_on_level_and_provider_id", unique: true
    t.check_constraint "level::text = ANY (ARRAY['artist'::character varying, 'release_group'::character varying, 'recording'::character varying]::text[])", name: "genre_classifications_level"
  end

  create_table "genres", force: :cascade do |t|
    t.string "slug", null: false
    t.string "name", null: false
    t.string "level", null: false
    t.bigint "parent_id"
    t.integer "position", default: 0, null: false
    t.string "origin", default: "seed", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["parent_id"], name: "index_genres_on_parent_id"
    t.index ["slug"], name: "index_genres_on_slug", unique: true
    t.check_constraint "(level::text = 'broad'::text) = (parent_id IS NULL)", name: "genres_parent"
    t.check_constraint "level::text = ANY (ARRAY['broad'::character varying, 'sub'::character varying]::text[])", name: "genres_level"
    t.check_constraint "origin::text = ANY (ARRAY['seed'::character varying, 'manual'::character varying]::text[])", name: "genres_origin"
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
    t.uuid "job_token"
    t.datetime "history_from"
    t.datetime "cutoff_at"
    t.integer "reported_playcount"
    t.bigint "current_window_id"
    t.datetime "last_activity_at"
    t.datetime "last_committed_at"
    t.datetime "last_scheduled_at"
    t.datetime "next_step_at"
    t.datetime "paused_at"
    t.datetime "cancelled_at"
    t.integer "stall_kicks", default: 0, null: false
    t.uuid "step_from_token"
    t.boolean "count_scan", default: false, null: false
    t.index ["user_id", "created_at"], name: "index_import_runs_on_user_id_and_created_at"
    t.index ["user_id", "kind", "started_at"], name: "index_import_runs_on_user_id_and_kind_and_started_at"
    t.index ["user_id"], name: "index_import_runs_on_user_id"
    t.index ["user_id"], name: "index_import_runs_one_active_per_user", unique: true, where: "((state)::text = ANY ((ARRAY['planning'::character varying, 'running'::character varying, 'paused'::character varying, 'needs_review'::character varying])::text[]))"
    t.check_constraint "kind::text = ANY (ARRAY['full'::character varying, 'sync'::character varying, 'catch_up'::character varying, 'reconcile'::character varying]::text[])", name: "import_runs_kind"
    t.check_constraint "state::text = ANY (ARRAY['planning'::character varying, 'running'::character varying, 'paused'::character varying, 'needs_review'::character varying, 'completed'::character varying, 'failed'::character varying, 'cancelled'::character varying]::text[])", name: "import_runs_state"
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
    t.integer "committed_count"
    t.integer "http_requests_used", default: 0, null: false
    t.integer "commit_attempts", default: 0, null: false
    t.datetime "retry_at"
    t.integer "http_requests_baseline", default: 0, null: false
    t.datetime "last_checked_at"
    t.bigint "last_check_fetch_id"
    t.jsonb "last_check_summary"
    t.datetime "check_from"
    t.datetime "check_to"
    t.datetime "last_verified_at"
    t.datetime "count_checked_at"
    t.integer "remote_count"
    t.string "review_reason"
    t.integer "present_count"
    t.datetime "count_mismatch_at"
    t.index ["import_run_id"], name: "index_import_windows_on_import_run_id"
    t.index ["parent_window_id"], name: "index_import_windows_on_parent_window_id"
    t.index ["user_id", "state", "retry_at"], name: "index_import_windows_on_user_id_and_state_and_retry_at"
    t.index ["user_id", "state"], name: "index_import_windows_on_user_id_and_state"
    t.index ["user_id", "window_from", "window_to"], name: "index_import_windows_on_user_id_and_window_from_and_window_to", unique: true
    t.index ["user_id"], name: "index_import_windows_on_user_id"
    t.check_constraint "(check_from IS NULL OR check_from >= window_from AND check_from <= window_to) AND (check_to IS NULL OR check_to > COALESCE(check_from, window_from))", name: "import_windows_check_range"
    t.check_constraint "(state::text <> ALL (ARRAY['validated'::character varying, 'committing'::character varying, 'committed'::character varying]::text[])) OR validated_at IS NOT NULL", name: "import_windows_validated_at"
    t.check_constraint "committed_count IS NULL OR committed_count >= 0", name: "import_windows_committed_count_non_negative"
    t.check_constraint "present_count IS NULL OR present_count >= 0", name: "import_windows_present_count"
    t.check_constraint "remote_count IS NULL OR remote_count >= 0", name: "import_windows_remote_count"
    t.check_constraint "review_reason IS NULL OR (review_reason::text = ANY (ARRAY['attempts_exhausted'::character varying, 'budget_exhausted'::character varying, 'unstable'::character varying, 'malformed_rows'::character varying, 'undated_rows'::character varying, 'out_of_range_rows'::character varying, 'too_large'::character varying, 'reconciliation_check'::character varying, 'incomplete_answer'::character varying, 'staging_inconsistent'::character varying, 'commit_error'::character varying]::text[]))", name: "import_windows_review_reason"
    t.check_constraint "state::text <> 'committed'::text OR committed_at IS NOT NULL", name: "import_windows_committed_at"
    t.check_constraint "state::text <> 'committed'::text OR committed_count IS NOT NULL", name: "import_windows_committed_count"
    t.check_constraint "state::text = ANY (ARRAY['pending'::character varying, 'fetching'::character varying, 'validating'::character varying, 'validated'::character varying, 'committing'::character varying, 'committed'::character varying, 'failed'::character varying, 'needs_review'::character varying, 'split'::character varying]::text[])", name: "import_windows_state"
    t.check_constraint "window_from < window_to", name: "import_windows_range"
    t.exclusion_constraint "user_id WITH =, tsrange(window_from, window_to, '[)'::text) WITH &&", where: "(state)::text <> 'split'::text", using: :gist, name: "import_windows_no_overlap"
  end

  create_table "inferred_artworks", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "subject_key", null: false
    t.string "provider", default: "listenbrainz_mapping", null: false
    t.text "release_id", null: false
    t.text "recording_id"
    t.integer "observations", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.jsonb "evidence", default: {}, null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "next_attempt_at"
    t.datetime "checked_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "subject_key"], name: "index_inferred_artworks_on_user_id_and_subject_key", unique: true
    t.index ["user_id"], name: "index_inferred_artworks_on_user_id"
    t.check_constraint "provider::text = 'listenbrainz_mapping'::text", name: "inferred_artworks_provider"
    t.check_constraint "status::text = ANY (ARRAY['pending'::text, 'ok'::text, 'none'::text, 'mismatch'::text, 'failed'::text])", name: "inferred_artworks_status"
  end

  create_table "lastfm_connections", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "identity_id", null: false
    t.string "history_state", default: "not_started", null: false
    t.datetime "last_synced_at"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "sync_paused_at"
    t.index ["identity_id"], name: "index_lastfm_connections_on_identity_id", unique: true
    t.index ["user_id"], name: "index_lastfm_connections_on_user_id", unique: true
    t.check_constraint "history_state::text = ANY (ARRAY['not_started'::character varying, 'importing'::character varying, 'imported'::character varying, 'failed'::character varying]::text[])", name: "lastfm_connections_history_state_check"
  end

  create_table "listening_gaps", force: :cascade do |t|
    t.bigint "listening_source_id", null: false
    t.uuid "user_id", null: false
    t.datetime "gap_from", null: false
    t.datetime "gap_to", null: false
    t.bigint "listening_poll_id"
    t.datetime "detected_at", null: false
    t.datetime "resolved_at"
    t.text "resolution"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["listening_poll_id"], name: "index_listening_gaps_on_listening_poll_id"
    t.index ["listening_source_id"], name: "index_listening_gaps_on_listening_source_id"
    t.index ["user_id", "gap_from"], name: "index_listening_gaps_on_user_id_and_gap_from"
    t.check_constraint "gap_from < gap_to", name: "listening_gaps_order"
  end

  create_table "listening_observations", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "listening_source_id", null: false
    t.string "provider", null: false
    t.text "source_event_id", null: false
    t.datetime "reported_at", null: false
    t.text "reported_at_raw", null: false
    t.string "timestamp_kind", null: false
    t.integer "duration_ms"
    t.bigint "name_variant_id", null: false
    t.text "provider_track_id"
    t.text "provider_album_id"
    t.text "provider_artist_ids", default: [], null: false, array: true
    t.text "isrc"
    t.jsonb "context"
    t.bigint "scrobble_id"
    t.string "link_state", null: false
    t.string "linked_by"
    t.jsonb "match_evidence", default: {}, null: false
    t.datetime "received_at", null: false
    t.datetime "last_seen_at", null: false
    t.integer "times_seen", default: 1, null: false
    t.jsonb "later_values"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["listening_source_id", "source_event_id"], name: "index_listening_observations_identity", unique: true
    t.index ["listening_source_id"], name: "index_listening_observations_on_listening_source_id"
    t.index ["name_variant_id"], name: "index_listening_observations_on_name_variant_id"
    t.index ["scrobble_id", "provider"], name: "index_listening_observations_one_per_provider", unique: true, where: "(scrobble_id IS NOT NULL)"
    t.index ["scrobble_id"], name: "index_listening_observations_on_scrobble_id"
    t.index ["user_id", "link_state"], name: "index_listening_observations_on_user_id_and_link_state"
    t.index ["user_id", "reported_at"], name: "index_listening_observations_on_user_id_and_reported_at"
    t.index ["user_id"], name: "index_listening_observations_on_user_id"
    t.check_constraint "(link_state::text = 'pending_review'::text) = (scrobble_id IS NULL)", name: "listening_observations_scrobble"
    t.check_constraint "link_state::text = ANY (ARRAY['created'::character varying, 'linked'::character varying, 'pending_review'::character varying]::text[])", name: "listening_observations_link_state"
    t.check_constraint "provider::text = ANY (ARRAY['spotify'::text, 'listenbrainz'::text])", name: "listening_observations_provider"
  end

  create_table "listening_polls", force: :cascade do |t|
    t.bigint "listening_source_id", null: false
    t.uuid "user_id", null: false
    t.string "trigger", null: false
    t.datetime "started_at", null: false
    t.datetime "finished_at"
    t.string "outcome"
    t.integer "http_requests", default: 0, null: false
    t.integer "pages", default: 0, null: false
    t.integer "items", default: 0, null: false
    t.integer "malformed", default: 0, null: false
    t.jsonb "recorded", default: {}, null: false
    t.datetime "oldest_reported_at"
    t.datetime "newest_reported_at"
    t.boolean "reached_known", default: false, null: false
    t.integer "retry_after"
    t.text "error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["listening_source_id", "started_at"], name: "index_listening_polls_on_listening_source_id_and_started_at"
    t.index ["listening_source_id"], name: "index_listening_polls_on_listening_source_id"
    t.check_constraint "trigger::text = ANY (ARRAY['schedule'::text, 'manual'::text, 'task'::text, 'backfill'::text])", name: "listening_polls_trigger"
  end

  create_table "listening_sources", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "provider", null: false
    t.text "external_account_id", null: false
    t.text "display_name"
    t.string "state", default: "connected", null: false
    t.text "credentials"
    t.text "scopes"
    t.datetime "connected_at", null: false
    t.datetime "disconnected_at"
    t.datetime "paused_at"
    t.text "last_error"
    t.datetime "last_error_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.datetime "last_poll_at"
    t.datetime "last_success_at"
    t.datetime "next_poll_at"
    t.integer "consecutive_failures", default: 0, null: false
    t.datetime "high_water_at"
    t.datetime "covered_from"
    t.datetime "last_new_play_at"
    t.integer "plays_added", default: 0, null: false
    t.string "backfill_state"
    t.datetime "backfill_before"
    t.integer "backfill_total"
    t.integer "backfill_fetched", default: 0, null: false
    t.datetime "backfill_started_at"
    t.datetime "backfill_finished_at"
    t.index ["provider", "external_account_id"], name: "index_listening_sources_on_provider_and_external_account_id", unique: true
    t.index ["user_id", "provider"], name: "index_listening_sources_on_user_id_and_provider"
    t.index ["user_id"], name: "index_listening_sources_on_user_id"
    t.check_constraint "backfill_state::text = ANY (ARRAY['running'::text, 'done'::text])", name: "listening_sources_backfill_state"
    t.check_constraint "provider::text = ANY (ARRAY['spotify'::text, 'listenbrainz'::text])", name: "listening_sources_provider"
    t.check_constraint "state::text = ANY (ARRAY['connected'::character varying, 'needs_reauth'::character varying, 'disconnected'::character varying]::text[])", name: "listening_sources_state"
  end

  create_table "loved_tracks", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "name_variant_id", null: false
    t.string "source", null: false
    t.datetime "loved_at", null: false
    t.text "source_url"
    t.datetime "first_imported_at"
    t.datetime "last_listed_at"
    t.datetime "unloved_at"
    t.boolean "manual", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name_variant_id"], name: "index_loved_tracks_on_name_variant_id"
    t.index ["user_id", "loved_at"], name: "index_loved_tracks_on_user_id_and_loved_at"
    t.index ["user_id", "name_variant_id", "source"], name: "index_loved_tracks_identity", unique: true
    t.index ["user_id"], name: "index_loved_tracks_on_user_id"
    t.check_constraint "source::text = ANY (ARRAY['lastfm'::text, 'runout'::text])", name: "loved_tracks_source"
  end

  create_table "mbid_disputes", force: :cascade do |t|
    t.binary "strings_hash", null: false
    t.string "level", null: false
    t.text "artist_name", null: false
    t.text "title"
    t.text "candidate_mbids", default: [], null: false, array: true
    t.integer "occurrences", default: 0, null: false
    t.bigint "first_import_window_id"
    t.datetime "first_seen_at", null: false
    t.datetime "last_seen_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["first_import_window_id"], name: "index_mbid_disputes_on_first_import_window_id"
    t.index ["strings_hash"], name: "index_mbid_disputes_on_strings_hash", unique: true
    t.check_constraint "(level::text = 'artist'::text) = (title IS NULL)", name: "mbid_disputes_title"
    t.check_constraint "level::text = ANY (ARRAY['artist'::character varying, 'album'::character varying, 'track'::character varying]::text[])", name: "mbid_disputes_level"
  end

  create_table "metadata_artists", force: :cascade do |t|
    t.string "provider", null: false
    t.text "provider_id", null: false
    t.text "canonical_id"
    t.text "name"
    t.text "sort_name"
    t.text "disambiguation"
    t.string "artist_type"
    t.string "gender"
    t.text "area_name"
    t.string "area_code"
    t.string "begin_date"
    t.string "end_date"
    t.boolean "ended"
    t.string "core_license", null: false
    t.text "source_url", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "provider_id"], name: "index_metadata_artists_on_provider_and_provider_id", unique: true
  end

  create_table "metadata_artworks", force: :cascade do |t|
    t.string "provider", null: false
    t.text "release_id", null: false
    t.text "release_group_id"
    t.string "found_on"
    t.text "image_id"
    t.text "thumbnail_250"
    t.text "thumbnail_500"
    t.text "thumbnail_1200"
    t.text "source_url", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "release_id"], name: "index_metadata_artworks_on_provider_and_release_id", unique: true
    t.check_constraint "(found_on::text = 'release_group'::text) <= (release_group_id IS NOT NULL)", name: "metadata_artworks_group"
    t.check_constraint "found_on IS NULL OR (found_on::text = ANY (ARRAY['release'::character varying, 'release_group'::character varying]::text[]))", name: "metadata_artworks_found_on"
  end

  create_table "metadata_fetches", force: :cascade do |t|
    t.string "provider", null: false
    t.string "entity_kind", null: false
    t.text "provider_id", null: false
    t.text "url", null: false
    t.integer "http_status"
    t.string "outcome", null: false
    t.integer "duration_ms"
    t.jsonb "changed_values", default: {}, null: false
    t.text "error"
    t.datetime "requested_at", null: false
    t.index ["provider", "entity_kind", "provider_id"], name: "index_metadata_fetches_entity"
  end

  create_table "metadata_overrides", force: :cascade do |t|
    t.string "entity_kind", null: false
    t.text "provider_id", null: false
    t.string "field", null: false
    t.jsonb "value", null: false
    t.text "note"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["entity_kind", "provider_id", "field"], name: "index_metadata_overrides_identity", unique: true
    t.check_constraint "field::text = ANY (ARRAY['genres'::character varying, 'artist_type'::character varying, 'gender'::character varying]::text[])", name: "metadata_overrides_field"
  end

  create_table "metadata_tags", force: :cascade do |t|
    t.string "provider", null: false
    t.string "entity_kind", null: false
    t.text "provider_id", null: false
    t.string "kind", null: false
    t.text "name", null: false
    t.integer "votes", null: false
    t.string "license", null: false
    t.datetime "fetched_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_metadata_tags_on_name"
    t.index ["provider", "entity_kind", "provider_id", "kind", "name"], name: "index_metadata_tags_identity", unique: true
    t.check_constraint "kind::text = ANY (ARRAY['genre'::character varying, 'tag'::character varying]::text[])", name: "metadata_tags_kind"
  end

  create_table "metadata_targets", force: :cascade do |t|
    t.string "provider", null: false
    t.string "entity_kind", null: false
    t.text "provider_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.integer "attempts", default: 0, null: false
    t.datetime "next_attempt_at", null: false
    t.datetime "last_attempt_at"
    t.datetime "last_success_at"
    t.integer "last_http_status"
    t.text "last_error"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["provider", "entity_kind", "provider_id"], name: "index_metadata_targets_identity", unique: true
    t.index ["status", "next_attempt_at", "priority"], name: "index_metadata_targets_due"
    t.check_constraint "status::text = ANY (ARRAY['pending'::character varying, 'ok'::character varying, 'not_found'::character varying, 'invalid'::character varying, 'failed'::character varying]::text[])", name: "metadata_targets_status"
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
    t.string "artist_match"
    t.string "album_match"
    t.string "track_match"
    t.integer "match_version"
    t.index "lower(album_name) gin_trgm_ops", name: "index_name_variants_on_album_name_trgm", using: :gin
    t.index "lower(artist_name) gin_trgm_ops", name: "index_name_variants_on_artist_name_trgm", using: :gin
    t.index "lower(track_name) gin_trgm_ops", name: "index_name_variants_on_track_name_trgm", using: :gin
    t.index ["album_id"], name: "index_name_variants_on_album_id"
    t.index ["artist_id"], name: "index_name_variants_on_artist_id"
    t.index ["match_version"], name: "index_name_variants_on_match_version"
    t.index ["track_id"], name: "index_name_variants_on_track_id"
    t.index ["variant_hash"], name: "index_name_variants_on_variant_hash", unique: true
    t.check_constraint "album_match IS NULL OR (album_match::text = ANY (ARRAY['mbid'::character varying, 'alias'::character varying, 'name'::character varying, 'manual'::character varying]::text[])) AND album_id IS NOT NULL OR (album_match::text = ANY (ARRAY['ambiguous'::character varying, 'unmatched'::character varying, 'none'::character varying]::text[])) AND album_id IS NULL", name: "name_variants_album_match"
    t.check_constraint "artist_match IS NULL OR (artist_match::text = ANY (ARRAY['mbid'::character varying, 'alias'::character varying, 'name'::character varying, 'manual'::character varying, 'inferred'::character varying]::text[])) AND artist_id IS NOT NULL OR (artist_match::text = ANY (ARRAY['ambiguous'::character varying, 'unmatched'::character varying]::text[])) AND artist_id IS NULL", name: "name_variants_artist_match"
    t.check_constraint "match_method IS NULL OR (match_method::text = ANY (ARRAY['mbid'::character varying, 'normalized_name'::character varying, 'manual'::character varying]::text[]))", name: "name_variants_match_method"
    t.check_constraint "octet_length(variant_hash) = 32", name: "name_variants_hash_length"
    t.check_constraint "track_match IS NULL OR (track_match::text = ANY (ARRAY['mbid'::character varying, 'alias'::character varying, 'name'::character varying, 'manual'::character varying]::text[])) AND track_id IS NOT NULL OR (track_match::text = ANY (ARRAY['ambiguous'::character varying, 'unmatched'::character varying]::text[])) AND track_id IS NULL", name: "name_variants_track_match"
  end

  create_table "reconciliation_disputes", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.bigint "import_window_id"
    t.datetime "played_at", null: false
    t.string "state", default: "open", null: false
    t.bigint "stored_scrobble_ids", default: [], null: false, array: true
    t.bigint "proposed_variant_ids", default: [], null: false, array: true
    t.string "evidence_key", null: false
    t.bigint "first_seen_fetch_id", null: false
    t.bigint "last_seen_fetch_id", null: false
    t.uuid "decided_by_id"
    t.datetime "decided_at"
    t.jsonb "resolution"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["decided_by_id"], name: "index_reconciliation_disputes_on_decided_by_id"
    t.index ["first_seen_fetch_id"], name: "index_reconciliation_disputes_on_first_seen_fetch_id"
    t.index ["import_window_id"], name: "index_reconciliation_disputes_on_import_window_id"
    t.index ["last_seen_fetch_id"], name: "index_reconciliation_disputes_on_last_seen_fetch_id"
    t.index ["user_id", "played_at"], name: "index_reconciliation_disputes_one_open", unique: true, where: "((state)::text = 'open'::text)"
    t.index ["user_id", "state"], name: "index_reconciliation_disputes_on_user_id_and_state"
    t.index ["user_id"], name: "index_reconciliation_disputes_on_user_id"
    t.check_constraint "(state::text = ANY (ARRAY['open'::character varying, 'superseded'::character varying]::text[])) OR decided_at IS NOT NULL", name: "reconciliation_disputes_decided"
    t.check_constraint "state::text = ANY (ARRAY['open'::character varying, 'resolved'::character varying, 'dismissed'::character varying, 'superseded'::character varying]::text[])", name: "reconciliation_disputes_state"
  end

  create_table "recovery_codes", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "code_digest", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["code_digest"], name: "index_recovery_codes_on_code_digest", unique: true
    t.index ["user_id"], name: "index_recovery_codes_on_user_id"
  end

  create_table "review_decisions", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "subject_type", null: false
    t.bigint "subject_id", null: false
    t.string "action", null: false
    t.string "source", null: false
    t.uuid "decided_by_id"
    t.jsonb "details", default: {}, null: false
    t.datetime "created_at", null: false
    t.index ["decided_by_id"], name: "index_review_decisions_on_decided_by_id"
    t.index ["subject_type", "subject_id"], name: "index_review_decisions_on_subject_type_and_subject_id"
    t.index ["user_id"], name: "index_review_decisions_on_user_id"
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
    t.index ["scrobble_id"], name: "index_scrobble_removals_one_open", unique: true, where: "((state)::text = ANY ((ARRAY['observed'::character varying, 'pending_review'::character varying, 'reappeared'::character varying])::text[]))"
    t.index ["user_id"], name: "index_scrobble_removals_on_user_id"
    t.check_constraint "(state::text <> ALL (ARRAY['approved'::character varying, 'dismissed'::character varying]::text[])) OR decided_at IS NOT NULL", name: "scrobble_removals_decided"
    t.check_constraint "state::text <> 'pending_review'::text OR confirming_fetch_id IS NOT NULL", name: "scrobble_removals_two_reads"
    t.check_constraint "state::text = ANY (ARRAY['observed'::character varying, 'pending_review'::character varying, 'approved'::character varying, 'dismissed'::character varying, 'restored'::character varying, 'reappeared'::character varying]::text[])", name: "scrobble_removals_state"
  end

  create_table "scrobbles", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.datetime "played_at", null: false
    t.integer "seq", limit: 2, default: 0, null: false
    t.bigint "name_variant_id", null: false
    t.datetime "removed_at"
    t.bigint "first_seen_fetch_id"
    t.datetime "created_at", null: false
    t.string "source", default: "lastfm", null: false
    t.index ["name_variant_id"], name: "index_scrobbles_on_name_variant_id"
    t.index ["user_id", "removed_at"], name: "index_scrobbles_on_user_id_and_removed_at", where: "(removed_at IS NOT NULL)"
    t.index ["user_id", "played_at", "seq"], name: "index_scrobbles_identity", unique: true
    t.check_constraint "seq >= 0", name: "scrobbles_seq_non_negative"
    t.check_constraint "source::text = ANY (ARRAY['lastfm'::text, 'spotify'::text, 'listenbrainz'::text])", name: "scrobbles_source"
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

  create_table "sign_in_links", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.string "token_digest", null: false
    t.datetime "expires_at", null: false
    t.datetime "used_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "kind", default: "recovery", null: false
    t.index ["token_digest"], name: "index_sign_in_links_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sign_in_links_on_user_id"
    t.check_constraint "kind::text = ANY (ARRAY['recovery'::text, 'invitation'::text])", name: "sign_in_links_kind"
  end

  create_table "tag_genre_mappings", force: :cascade do |t|
    t.text "tag", null: false
    t.bigint "genre_id", null: false
    t.decimal "weight", precision: 4, scale: 3, null: false
    t.string "origin", default: "seed", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["genre_id"], name: "index_tag_genre_mappings_on_genre_id"
    t.index ["tag", "genre_id"], name: "index_tag_genre_mappings_on_tag_and_genre_id", unique: true
    t.index ["tag"], name: "index_tag_genre_mappings_on_tag"
    t.check_constraint "origin::text = ANY (ARRAY['seed'::character varying, 'manual'::character varying, 'musicbrainz'::character varying]::text[])", name: "tag_genre_mappings_origin"
    t.check_constraint "weight > 0::numeric AND weight <= 1::numeric", name: "tag_genre_mappings_weight"
  end

  create_table "taxonomy_settings", primary_key: "key", id: :string, force: :cascade do |t|
    t.decimal "value", precision: 8, scale: 3, null: false
    t.string "origin", default: "seed", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "tracks", force: :cascade do |t|
    t.bigint "artist_id", null: false
    t.text "title", null: false
    t.text "normalized_title", null: false
    t.text "mbid"
    t.bigint "merged_into_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "inference_id"
    t.index ["artist_id", "normalized_title"], name: "index_tracks_on_artist_id_and_normalized_title"
    t.index ["artist_id"], name: "index_tracks_on_artist_id"
    t.index ["inference_id"], name: "index_tracks_on_inference_id"
    t.index ["mbid"], name: "index_tracks_on_mbid", unique: true, where: "(mbid IS NOT NULL)"
    t.index ["merged_into_id"], name: "index_tracks_on_merged_into_id"
    t.index ["normalized_title"], name: "index_tracks_on_normalized_title_trgm", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "users", id: :uuid, default: -> { "gen_random_uuid()" }, force: :cascade do |t|
    t.string "display_name", null: false
    t.string "reporting_timezone", default: "UTC", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "webauthn_handle"
    t.string "theme"
    t.index ["webauthn_handle"], name: "index_users_on_webauthn_handle", unique: true
  end

  create_table "webauthn_credentials", force: :cascade do |t|
    t.uuid "user_id", null: false
    t.text "external_id", null: false
    t.text "public_key", null: false
    t.bigint "sign_count", default: 0, null: false
    t.string "nickname"
    t.text "transports", default: [], null: false, array: true
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["external_id"], name: "index_webauthn_credentials_on_external_id", unique: true
    t.index ["user_id"], name: "index_webauthn_credentials_on_user_id"
  end

  add_foreign_key "albums", "albums", column: "merged_into_id"
  add_foreign_key "albums", "artists"
  add_foreign_key "albums", "catalogue_inferences", column: "inference_id"
  add_foreign_key "artist_aliases", "artists", on_delete: :cascade
  add_foreign_key "artists", "artists", column: "merged_into_id"
  add_foreign_key "artists", "catalogue_inferences", column: "inference_id"
  add_foreign_key "catalogue_inferences", "artists", column: "from_id"
  add_foreign_key "catalogue_inferences", "artists", column: "into_id"
  add_foreign_key "catalogue_reviews", "catalogue_inferences", column: "inference_id"
  add_foreign_key "catalogue_reviews", "name_variants", on_delete: :cascade
  add_foreign_key "catalogue_reviews", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "genres", "genres", column: "parent_id"
  add_foreign_key "identities", "users", on_delete: :cascade
  add_foreign_key "import_runs", "users", on_delete: :cascade
  add_foreign_key "import_window_fetches", "import_windows", on_delete: :cascade
  add_foreign_key "import_window_rows", "import_window_fetches", on_delete: :cascade
  add_foreign_key "import_windows", "import_runs", on_delete: :nullify
  add_foreign_key "import_windows", "import_windows", column: "parent_window_id", on_delete: :cascade
  add_foreign_key "import_windows", "users", on_delete: :cascade
  add_foreign_key "inferred_artworks", "users", on_delete: :cascade
  add_foreign_key "lastfm_connections", "identities", on_delete: :cascade
  add_foreign_key "lastfm_connections", "users", on_delete: :cascade
  add_foreign_key "listening_gaps", "listening_polls", on_delete: :nullify
  add_foreign_key "listening_gaps", "listening_sources", on_delete: :cascade
  add_foreign_key "listening_observations", "listening_sources", on_delete: :cascade
  add_foreign_key "listening_observations", "name_variants"
  add_foreign_key "listening_observations", "scrobbles"
  add_foreign_key "listening_observations", "users", on_delete: :cascade
  add_foreign_key "listening_polls", "listening_sources", on_delete: :cascade
  add_foreign_key "listening_sources", "users", on_delete: :cascade
  add_foreign_key "loved_tracks", "name_variants"
  add_foreign_key "loved_tracks", "users", on_delete: :cascade
  add_foreign_key "mbid_disputes", "import_windows", column: "first_import_window_id", on_delete: :nullify
  add_foreign_key "name_variants", "albums"
  add_foreign_key "name_variants", "artists"
  add_foreign_key "name_variants", "tracks"
  add_foreign_key "reconciliation_disputes", "import_window_fetches", column: "first_seen_fetch_id"
  add_foreign_key "reconciliation_disputes", "import_window_fetches", column: "last_seen_fetch_id"
  add_foreign_key "reconciliation_disputes", "import_windows", on_delete: :nullify
  add_foreign_key "reconciliation_disputes", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "reconciliation_disputes", "users", on_delete: :cascade
  add_foreign_key "recovery_codes", "users", on_delete: :cascade
  add_foreign_key "review_decisions", "users", column: "decided_by_id", on_delete: :nullify
  add_foreign_key "review_decisions", "users", on_delete: :cascade
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
  add_foreign_key "sign_in_links", "users", on_delete: :cascade
  add_foreign_key "tag_genre_mappings", "genres", on_delete: :cascade
  add_foreign_key "tracks", "artists"
  add_foreign_key "tracks", "catalogue_inferences", column: "inference_id"
  add_foreign_key "tracks", "tracks", column: "merged_into_id"
  add_foreign_key "webauthn_credentials", "users", on_delete: :cascade
end
