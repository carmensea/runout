# Listening history and its reconciliation records. docs/milestone-2-plan.md §4.4 and §6.1.
class CreateScrobbles < ActiveRecord::Migration[8.1]
  def change
    # One row per play. Last.fm gives plays no ID, so each gets its own internal `id`, and identity
    # within a user is (played_at, seq): seq numbers the plays recorded in the same second (0, 1, ...).
    # Track identity is deliberately not part of the key: two identical plays in one second are two
    # rows, and a corrected name never creates a second row.
    #
    # Kept lean (~209k rows for the first real account): no updated_at, and no separate range index,
    # because the unique (user_id, played_at, seq) index already serves user-scoped date ranges.
    create_table :scrobbles do |t|
      t.references :user, type: :uuid, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.datetime :played_at, null: false
      t.integer :seq, limit: 2, null: false, default: 0
      t.references :name_variant, null: false, foreign_key: true # on_delete restrict: variants outlive references
      t.datetime :removed_at # set only when a removal proposal is approved
      t.references :first_seen_fetch, index: false, foreign_key: { to_table: :import_window_fetches, on_delete: :nullify }
      t.datetime :created_at, null: false
    end
    add_index :scrobbles, [ :user_id, :played_at, :seq ], unique: true, name: "index_scrobbles_identity"
    add_check_constraint :scrobbles, "seq >= 0", name: "scrobbles_seq_non_negative"

    # A changed name for an existing play. Applied only when unambiguous; anything uncertain waits
    # for review and the scrobble keeps its original variant until then. Rows are never deleted.
    create_table :scrobble_corrections do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :scrobble, null: false, foreign_key: { on_delete: :cascade }
      t.references :from_variant, null: false, foreign_key: { to_table: :name_variants }
      t.references :to_variant, null: false, foreign_key: { to_table: :name_variants }
      t.references :import_window_fetch, foreign_key: { on_delete: :nullify }
      t.string :state, null: false   # applied | pending_review | dismissed
      t.string :reason, null: false  # why it was applied automatically, or why it needs review
      t.datetime :decided_at
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :decision_note
      t.timestamps
    end
    add_check_constraint :scrobble_corrections, "state IN ('applied', 'pending_review', 'dismissed')", name: "scrobble_corrections_state"
    add_check_constraint :scrobble_corrections, "from_variant_id <> to_variant_id", name: "scrobble_corrections_changes_something"
    add_check_constraint :scrobble_corrections, "state = 'pending_review' OR decided_at IS NOT NULL", name: "scrobble_corrections_decided"
    add_index :scrobble_corrections, :scrobble_id, unique: true, where: "state = 'pending_review'",
              name: "index_scrobble_corrections_one_open"

    # A play that Last.fm no longer returns. Never applied automatically: it becomes pending_review
    # after two consecutive verified fetches agree, and only an approval sets scrobbles.removed_at.
    # `restored` means the play reappeared upstream. Rows are never deleted.
    create_table :scrobble_removals do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :scrobble, null: false, foreign_key: { on_delete: :cascade }
      t.references :first_missing_fetch, null: false, foreign_key: { to_table: :import_window_fetches }
      t.references :confirming_fetch, foreign_key: { to_table: :import_window_fetches }
      t.string :state, null: false, default: "observed" # observed | pending_review | approved | dismissed | restored
      t.datetime :decided_at
      t.references :decided_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.text :decision_note
      t.timestamps
    end
    add_check_constraint :scrobble_removals, "state IN ('observed', 'pending_review', 'approved', 'dismissed', 'restored')",
                         name: "scrobble_removals_state"
    add_check_constraint :scrobble_removals, "state <> 'pending_review' OR confirming_fetch_id IS NOT NULL",
                         name: "scrobble_removals_two_reads"
    add_check_constraint :scrobble_removals, "state NOT IN ('approved', 'dismissed') OR decided_at IS NOT NULL",
                         name: "scrobble_removals_decided"
    add_index :scrobble_removals, :scrobble_id, unique: true, where: "state IN ('observed', 'pending_review')",
              name: "index_scrobble_removals_one_open"
  end
end
