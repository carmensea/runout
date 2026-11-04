# Runout's own sign-in (docs/milestone-5-plan.md §2): passkeys, recovery codes and the operator's
# emergency link. Additive only: users, identities, sessions and the history tables are unchanged.
# The user handle is the WebAuthn user id, generated on the first enrolment and never derived from
# anything else; it is stored in the gem's base64url encoding.
class CreatePasskeySignIn < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :webauthn_handle, :string
    add_index :users, :webauthn_handle, unique: true

    create_table :webauthn_credentials do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.text :external_id, null: false         # the credential id the authenticator chose
      t.text :public_key, null: false
      t.bigint :sign_count, null: false, default: 0
      t.string :nickname
      t.text :transports, array: true, null: false, default: []
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.timestamps
      t.index :external_id, unique: true
    end

    create_table :recovery_codes do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :code_digest, null: false
      t.datetime :used_at
      t.timestamps
      t.index :code_digest, unique: true
    end

    create_table :sign_in_links do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.timestamps
      t.index :token_digest, unique: true
    end
  end
end
