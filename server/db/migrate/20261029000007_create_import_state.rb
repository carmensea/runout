# Import bookkeeping: runs, time windows, fetch attempts and staged snapshots.
# docs/milestone-2-plan.md §4 and §6.2.
class CreateImportState < ActiveRecord::Migration[8.1]
  WINDOW_STATES = %w[pending fetching validating validated committing committed failed needs_review split].freeze

  def change
    enable_extension "btree_gist" # for the no-overlap exclusion constraint on windows

    create_table :import_runs do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false   # full | sync | catch_up | reconcile
      t.string :state, null: false, default: "planning"
      t.integer :expected_scrobbles # Last.fm playcount when the run started
      t.integer :committed_scrobbles, null: false, default: 0
      t.datetime :started_at
      t.datetime :finished_at
      t.text :last_error
      t.timestamps
    end
    add_index :import_runs, [ :user_id, :created_at ]
    add_check_constraint :import_runs, "kind IN ('full', 'sync', 'catch_up', 'reconcile')", name: "import_runs_kind"
    add_check_constraint :import_runs, "state IN ('planning', 'running', 'completed', 'failed', 'cancelled')", name: "import_runs_state"

    # A bounded UTC range [window_from, window_to), matching Last.fm's from-inclusive, to-exclusive
    # behaviour (docs/lastfm-api-findings.md, A2).
    create_table :import_windows do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :import_run, foreign_key: { on_delete: :nullify } # latest run to touch it
      t.references :parent_window, foreign_key: { to_table: :import_windows, on_delete: :cascade } # set when split
      t.datetime :window_from, null: false
      t.datetime :window_to, null: false
      t.string :state, null: false, default: "pending"
      t.integer :expected_total
      t.integer :fetched_count
      t.integer :malformed_count, null: false, default: 0
      t.integer :attempts, null: false, default: 0
      # Lease for crash recovery: a worker claims the window until lease_expires_at; an expired
      # lease may be reclaimed. claim_token identifies the holder.
      t.uuid :claim_token
      t.datetime :lease_expires_at
      t.integer :last_http_status
      t.integer :last_lastfm_error
      t.integer :last_error_page
      t.text :last_error_message
      t.datetime :validated_at
      t.datetime :committed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_index :import_windows, [ :user_id, :window_from, :window_to ], unique: true
    add_index :import_windows, [ :user_id, :state ]
    add_check_constraint :import_windows, "window_from < window_to", name: "import_windows_range"
    add_check_constraint :import_windows, "state IN (#{WINDOW_STATES.map { |s| "'#{s}'" }.join(', ')})", name: "import_windows_state"
    add_check_constraint :import_windows, "state <> 'committed' OR committed_at IS NOT NULL", name: "import_windows_committed_at"
    add_check_constraint :import_windows, "state NOT IN ('validated', 'committing', 'committed') OR validated_at IS NOT NULL",
                         name: "import_windows_validated_at"
    # Live windows of one user never overlap, so every play belongs to exactly one window.
    # A window replaced by smaller ones is marked 'split' and no longer counts.
    # tsrange, not tstzrange: Rails stores datetimes as UTC `timestamp without time zone`, and only
    # tsrange over those columns is immutable (usable in an index).
    add_exclusion_constraint :import_windows, "user_id WITH =, tsrange(window_from, window_to, '[)') WITH &&",
                             using: :gist, where: "state <> 'split'", name: "import_windows_no_overlap"

    # One row per fetch attempt of a window, kept for audit and for the two-reads removal rule.
    create_table :import_window_fetches do |t|
      t.references :import_window, null: false, foreign_key: { on_delete: :cascade }
      t.integer :attempt, null: false
      t.string :outcome, null: false, default: "in_progress" # in_progress | validated | mismatch | failed
      t.integer :expected_total
      t.integer :row_count, null: false, default: 0
      t.integer :malformed_count, null: false, default: 0
      t.integer :http_status
      t.integer :lastfm_error
      t.integer :error_page
      t.text :error_message
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.timestamps
    end
    add_index :import_window_fetches, [ :import_window_id, :attempt ], unique: true
    add_check_constraint :import_window_fetches, "outcome IN ('in_progress', 'validated', 'mismatch', 'failed')",
                         name: "import_window_fetches_outcome"

    # Staged snapshot of one fetch, deleted once the window commits (or the fetch is discarded).
    create_table :import_window_rows do |t|
      t.references :import_window_fetch, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.datetime :played_at, null: false
      t.integer :position, null: false   # order within the second, as Last.fm returned it
      t.integer :occurrence, null: false # nth identical (played_at, variant) in this snapshot
      t.binary :variant_hash, null: false
      t.text :artist_name, null: false
      t.text :track_name, null: false
      t.text :album_name, null: false, default: ""
      t.text :artist_mbid
      t.text :track_mbid
      t.text :album_mbid
    end
    add_index :import_window_rows, [ :import_window_fetch_id, :played_at, :position ], unique: true,
              name: "index_import_window_rows_identity"
    add_index :import_window_rows, [ :import_window_fetch_id, :played_at, :variant_hash, :occurrence ], unique: true,
              name: "index_import_window_rows_occurrence"
  end
end
