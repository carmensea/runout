# Stage 2.7: ongoing synchronisation (docs/milestone-2-plan.md §5).
#
# import_windows:
# - check_from / check_to: the part of the window the current check fetches and reconciles, when
#   it isn't the whole window. check_to may lie past window_to: the window then grows to check_to
#   when the check commits (the current month extended by sync), never before, so coverage only
#   ever includes committed ranges.
# - last_verified_at: when the whole window was last confirmed by one validated snapshot
#   (last_checked_at is now any successful check, partial ones included).
# - count_checked_at / remote_count: the weekly count comparison. A discovery signal only:
#   equal counts don't prove equal contents.
#
# import_runs.count_scan: a weekly reconcile run compares month counts before rechecking.
class AddHistorySync < ActiveRecord::Migration[8.1]
  def up
    change_table :import_windows, bulk: true do |t|
      t.datetime :check_from
      t.datetime :check_to
      t.datetime :last_verified_at
      t.datetime :count_checked_at
      t.integer :remote_count
    end
    add_check_constraint :import_windows,
                         "(check_from IS NULL OR (check_from >= window_from AND check_from <= window_to)) " \
                         "AND (check_to IS NULL OR check_to > COALESCE(check_from, window_from))",
                         name: "import_windows_check_range"
    add_check_constraint :import_windows, "remote_count IS NULL OR remote_count >= 0", name: "import_windows_remote_count"
    # Every check before this stage covered the whole window.
    execute "UPDATE import_windows SET last_verified_at = COALESCE(last_checked_at, committed_at) WHERE committed_at IS NOT NULL"

    add_column :import_runs, :count_scan, :boolean, null: false, default: false
    add_index :import_runs, [ :user_id, :kind, :started_at ]
  end

  def down
    remove_index :import_runs, [ :user_id, :kind, :started_at ]
    remove_column :import_runs, :count_scan
    remove_check_constraint :import_windows, name: "import_windows_remote_count"
    remove_check_constraint :import_windows, name: "import_windows_check_range"
    change_table :import_windows, bulk: true do |t|
      t.remove :check_from, :check_to, :last_verified_at, :count_checked_at, :remote_count
    end
  end
end
