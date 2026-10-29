class CreateLastfmConnections < ActiveRecord::Migration[8.1]
  def change
    create_table :lastfm_connections do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.references :identity, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :history_state, null: false, default: "not_started"
      t.datetime :last_synced_at
      t.text :last_error
      t.timestamps
    end
    add_check_constraint :lastfm_connections,
      "history_state IN ('not_started', 'importing', 'imported', 'failed')",
      name: "lastfm_connections_history_state_check"
  end
end
