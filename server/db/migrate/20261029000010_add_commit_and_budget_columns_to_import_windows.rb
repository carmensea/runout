# Stage 2.4: commit counts, and request accounting that persists across validation runs and job
# retries (docs/milestone-2-plan.md §7.3, "Combined retry budget").
class AddCommitAndBudgetColumnsToImportWindows < ActiveRecord::Migration[8.1]
  def change
    add_column :import_windows, :committed_count, :integer
    # Outbound HTTP attempts made for this window across every run, client retries included.
    add_column :import_windows, :http_requests_used, :integer, null: false, default: 0
    add_check_constraint :import_windows, "state <> 'committed' OR committed_count IS NOT NULL",
                         name: "import_windows_committed_count"
    add_check_constraint :import_windows, "committed_count IS NULL OR committed_count >= 0",
                         name: "import_windows_committed_count_non_negative"
  end
end
