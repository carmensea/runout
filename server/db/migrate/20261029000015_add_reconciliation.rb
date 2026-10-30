# Stage 2.4b: reconciling committed months against later validated snapshots
# (docs/milestone-2-plan.md §4.4). Additive: new tables and columns, one wider check constraint and
# a rebuilt partial index; no existing rows change.
class AddReconciliation < ActiveRecord::Migration[8.1]
  OLD_REMOVAL_STATES = %w[observed pending_review approved dismissed restored].freeze
  NEW_REMOVAL_STATES = %w[observed pending_review approved dismissed restored reappeared].freeze

  def change
    # A second where stored and fetched plays differ on both sides. Nothing in that second changes
    # until a person decides; the evidence (stored plays, fetched plays as immutable name variants)
    # is kept here.
    create_table :reconciliation_disputes do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :import_window, foreign_key: { on_delete: :nullify }
      t.datetime :played_at, null: false
      t.string :state, null: false, default: "open"
      t.bigint :stored_scrobble_ids, array: true, null: false, default: []
      t.bigint :proposed_variant_ids, array: true, null: false, default: [] # one entry per fetched play
      t.string :evidence_key, null: false # identifies the evidence, to tell new evidence from unchanged
      t.references :first_seen_fetch, null: false, foreign_key: { to_table: :import_window_fetches }
      t.references :last_seen_fetch, null: false, foreign_key: { to_table: :import_window_fetches }
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :decided_at
      t.jsonb :resolution
      t.timestamps
      t.index [ :user_id, :played_at ], unique: true, where: "state = 'open'", name: "index_reconciliation_disputes_one_open"
      t.index [ :user_id, :state ]
      t.check_constraint "state IN ('open', 'resolved', 'dismissed', 'superseded')", name: "reconciliation_disputes_state"
      t.check_constraint "state IN ('open', 'superseded') OR decided_at IS NOT NULL", name: "reconciliation_disputes_decided"
    end

    # Audit trail of every review decision and automatic review transition. Never updated or deleted
    # (except with the account).
    create_table :review_decisions do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :subject_type, null: false
      t.bigint :subject_id, null: false
      t.string :action, null: false
      t.string :source, null: false
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
      t.index [ :subject_type, :subject_id ]
    end

    # An approved (soft-deleted) play that Last.fm returns again: open for review.
    remove_check_constraint :scrobble_removals, states_sql(OLD_REMOVAL_STATES), name: "scrobble_removals_state"
    add_check_constraint :scrobble_removals, states_sql(NEW_REMOVAL_STATES), name: "scrobble_removals_state"
    remove_index :scrobble_removals, :scrobble_id, unique: true, where: "state IN ('observed', 'pending_review')",
                                                  name: "index_scrobble_removals_one_open"
    add_index :scrobble_removals, :scrobble_id, unique: true, where: "state IN ('observed', 'pending_review', 'reappeared')",
                                               name: "index_scrobble_removals_one_open"

    # Synchronisation status, kept apart from import coverage (committed_at) and review status.
    change_table :import_windows, bulk: true do |t|
      t.datetime :last_checked_at # last successful commit or reconciliation against Last.fm
      t.bigint :last_check_fetch_id
      t.jsonb :last_check_summary
    end
  end

  private

  def states_sql(states) = "state IN (#{states.map { |s| "'#{s}'" }.join(', ')})"
end
