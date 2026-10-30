# Stage 2.6: import orchestration and recovery (docs/milestone-2-plan.md §7). Additive: new columns,
# a wider run-state constraint and one index; no existing data changes.
class AddImportOrchestration < ActiveRecord::Migration[8.1]
  OLD_STATES = %w[planning running completed failed cancelled].freeze
  NEW_STATES = %w[planning running paused needs_review completed failed cancelled].freeze

  def change
    change_table :import_runs, bulk: true do |t|
      t.uuid :job_token               # the one job chain allowed to act for this run
      t.datetime :history_from        # first month imported (the account's registration month)
      t.datetime :cutoff_at           # imported up to here; later plays are for sync
      t.integer :reported_playcount   # Last.fm's playcount for the account, at the last check
      t.bigint :current_window_id
      t.datetime :last_activity_at    # last step that did something
      t.datetime :last_committed_at   # last window durably committed
      t.datetime :last_scheduled_at   # last job enqueued for this run
      t.datetime :next_step_at        # a step is deliberately scheduled for later (retry backoff)
      t.datetime :paused_at
      t.datetime :cancelled_at
    end
    remove_check_constraint :import_runs, states_sql(OLD_STATES), name: "import_runs_state"
    add_check_constraint :import_runs, states_sql(NEW_STATES), name: "import_runs_state"
    add_index :import_runs, :user_id, unique: true, where: "state IN ('planning', 'running', 'paused', 'needs_review')",
                                      name: "index_import_runs_one_active_per_user"

    change_table :import_windows, bulk: true do |t|
      t.integer :commit_attempts, null: false, default: 0
      t.datetime :retry_at # failed or validated: when to try again; NULL on a failed window means "gave up"
      t.integer :http_requests_baseline, null: false, default: 0 # http_requests_used when last manually retried
    end
    add_index :import_windows, [ :user_id, :state, :retry_at ]
  end

  private

  def states_sql(states) = "state IN (#{states.map { |s| "'#{s}'" }.join(', ')})"
end
