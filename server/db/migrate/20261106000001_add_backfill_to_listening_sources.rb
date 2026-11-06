# ListenBrainz backfill progress (docs/listenbrainz-spotify-feasibility.md §4.4): a durable cursor
# and counters on the source, and a `backfill` trigger for its poll rows.
class AddBackfillToListeningSources < ActiveRecord::Migration[8.1]
  def up
    add_column :listening_sources, :backfill_state, :string
    add_column :listening_sources, :backfill_before, :datetime
    add_column :listening_sources, :backfill_total, :integer
    add_column :listening_sources, :backfill_fetched, :integer, default: 0, null: false
    add_column :listening_sources, :backfill_started_at, :datetime
    add_column :listening_sources, :backfill_finished_at, :datetime
    add_check_constraint :listening_sources, "backfill_state IN ('running', 'done')", name: "listening_sources_backfill_state"
    remove_check_constraint :listening_polls, name: "listening_polls_trigger"
    add_check_constraint :listening_polls, "trigger IN ('schedule', 'manual', 'task', 'backfill')", name: "listening_polls_trigger"
  end

  def down
    remove_check_constraint :listening_polls, name: "listening_polls_trigger"
    add_check_constraint :listening_polls, "trigger IN ('schedule', 'manual', 'task')", name: "listening_polls_trigger"
    remove_check_constraint :listening_sources, name: "listening_sources_backfill_state"
    remove_column :listening_sources, :backfill_finished_at
    remove_column :listening_sources, :backfill_started_at
    remove_column :listening_sources, :backfill_fetched
    remove_column :listening_sources, :backfill_total
    remove_column :listening_sources, :backfill_before
    remove_column :listening_sources, :backfill_state
  end
end
