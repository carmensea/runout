# Stage 2.6: how many times the watchdog has restarted a stalled run without progress, so it gives
# up after a bounded number instead of restarting forever.
class AddStallKicksToImportRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :import_runs, :stall_kicks, :integer, null: false, default: 0
  end
end
