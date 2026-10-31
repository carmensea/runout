# Listening sources, stage 3 (docs/spotify-plan.md §10): polling a source, and what it can and
# can't confirm.
#
# - `listening_sources` gains its polling state: when it last ran and succeeded, when it may run
#   next (backoff, Retry-After), the newest play it has recorded (`high_water_at`), where its
#   confirmed coverage starts (`covered_from`), and counters for Settings.
# - `listening_polls`: one row per poll, with what it fetched and recorded, or why it failed.
# - `listening_gaps`: intervals the provider may no longer be able to return: the newest play
#   recorded before, and the oldest the provider still returned, when it returned as many as it
#   can. Plays in a gap may be lost; nothing is ever made up for them. A later import (for example
#   a streaming-history file) can resolve one.
#
# Additive only.
class CreateListeningPolls < ActiveRecord::Migration[8.1]
  def change
    change_table :listening_sources, bulk: true do |t|
      t.datetime :last_poll_at
      t.datetime :last_success_at
      t.datetime :next_poll_at
      t.integer :consecutive_failures, null: false, default: 0
      t.datetime :high_water_at, precision: 6        # the newest play recorded from this source
      t.datetime :covered_from, precision: 6         # the oldest play the first successful poll returned
      t.datetime :last_new_play_at                   # when a poll last recorded a new play
      t.integer :plays_added, null: false, default: 0
    end

    create_table :listening_polls do |t|
      t.references :listening_source, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :user_id, null: false
      t.string :trigger, null: false                 # schedule, manual, task
      t.datetime :started_at, null: false
      t.datetime :finished_at
      t.string :outcome                              # ok, rate_limited, unavailable, forbidden, needs_reauth, failed
      t.integer :http_requests, null: false, default: 0
      t.integer :pages, null: false, default: 0
      t.integer :items, null: false, default: 0
      t.integer :malformed, null: false, default: 0
      t.jsonb :recorded, null: false, default: {}    # outcome => count (Listening::Recorder)
      t.datetime :oldest_reported_at, precision: 6
      t.datetime :newest_reported_at, precision: 6
      t.boolean :reached_known, null: false, default: false # overlapped plays recorded before
      t.integer :retry_after
      t.text :error
      t.timestamps
      t.index [ :listening_source_id, :started_at ]
      t.check_constraint "trigger IN ('schedule', 'manual', 'task')", name: "listening_polls_trigger"
    end

    create_table :listening_gaps do |t|
      t.references :listening_source, null: false, foreign_key: { on_delete: :cascade }
      t.uuid :user_id, null: false
      t.datetime :gap_from, precision: 6, null: false  # the newest play recorded before
      t.datetime :gap_to, precision: 6, null: false    # the oldest play the provider still returned
      t.references :listening_poll, foreign_key: { on_delete: :nullify }
      t.datetime :detected_at, null: false
      t.datetime :resolved_at
      t.text :resolution
      t.timestamps
      t.index [ :user_id, :gap_from ]
      t.check_constraint "gap_from < gap_to", name: "listening_gaps_order"
    end
  end
end
