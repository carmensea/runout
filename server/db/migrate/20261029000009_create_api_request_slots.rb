# Shared request pacing for external APIs (Lastfm::RequestPacer). One row per API holds the next
# time a request may start; every process reserves slots from it atomically, so pacing holds
# across Puma threads and Solid Queue workers alike. Not history data.
class CreateApiRequestSlots < ActiveRecord::Migration[8.1]
  def change
    create_table :api_request_slots, id: false do |t|
      t.string :key, null: false, primary_key: true
      t.timestamptz :next_slot_at, null: false
      t.timestamptz :updated_at, null: false
    end
  end
end
