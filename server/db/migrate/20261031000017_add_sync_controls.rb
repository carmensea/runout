# Stage 2.8 (docs/milestone-2-plan.md §15).
#
# import_windows:
# - review_reason: why a period stopped for review, as a code. Transient reasons are retried
#   automatically (bounded); integrity reasons wait for a person (§15.6).
# - present_count / count_mismatch_at: measured in the background (weekly comparison, nightly
#   count check), so the status endpoint never counts plays per request (§15.7).
#
# lastfm_connections.sync_paused_at: the owner paused automatic synchronisation (nothing is
# cancelled or deleted).
class AddSyncControls < ActiveRecord::Migration[8.1]
  REASONS = %w[attempts_exhausted budget_exhausted unstable malformed_rows undated_rows out_of_range_rows too_large
               reconciliation_check incomplete_answer staging_inconsistent commit_error].freeze

  def change
    change_table :import_windows, bulk: true do |t|
      t.string :review_reason
      t.integer :present_count
      t.datetime :count_mismatch_at
    end
    add_check_constraint :import_windows, "review_reason IS NULL OR review_reason IN (#{REASONS.map { |r| "'#{r}'" }.join(', ')})",
                         name: "import_windows_review_reason"
    add_check_constraint :import_windows, "present_count IS NULL OR present_count >= 0", name: "import_windows_present_count"
    add_column :lastfm_connections, :sync_paused_at, :datetime
  end
end
