class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # SHA-256 of the random cookie token; the token itself is never stored.
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :last_seen_at, null: false
      t.string :ip_address
      t.string :user_agent
      t.timestamps
    end
    add_index :sessions, :token_digest, unique: true
    add_index :sessions, :expires_at
  end
end
