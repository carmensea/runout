# A way of signing in. Last.fm is the only provider for now; others add rows, not columns.
class CreateIdentities < ActiveRecord::Migration[8.1]
  def change
    create_table :identities do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :provider, null: false
      # Stable external account ID. For Last.fm this is the numeric user.getInfo id,
      # not the username, which Pro users can change.
      t.string :uid, null: false
      t.string :username
      t.string :profile_url
      t.datetime :registered_at
      # Provider secrets (the Last.fm session key), encrypted with Active Record Encryption.
      t.text :credentials
      t.datetime :last_authenticated_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :identities, [ :provider, :uid ], unique: true
    add_index :identities, [ :user_id, :provider ], unique: true
  end
end
