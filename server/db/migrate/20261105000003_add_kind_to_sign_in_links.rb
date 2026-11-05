# Invitations (docs/multi-user-plan.md §3, PR 2) reuse the operator's single-use link: `kind`
# tells an invitation (24 hours, dead once the account has a passkey) from the emergency recovery
# link (15 minutes). Additive; existing rows are recovery links.
class AddKindToSignInLinks < ActiveRecord::Migration[8.1]
  def change
    add_column :sign_in_links, :kind, :string, null: false, default: "recovery"
    add_check_constraint :sign_in_links, "kind IN ('recovery', 'invitation')", name: "sign_in_links_kind"
  end
end
