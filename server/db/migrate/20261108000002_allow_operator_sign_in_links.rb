# The operator's sign-in-as link is a third kind of SignInLink ("operator"): it opens an operator
# session (sessions.operator). Same restore-safe spelling as RestoreSafeCheckConstraints.
class AllowOperatorSignInLinks < ActiveRecord::Migration[8.1]
  def up
    swap "kind::text IN ('recovery', 'invitation', 'operator')"
  end

  def down
    swap "kind::text IN ('recovery', 'invitation')"
  end

  private

  def swap(expression)
    remove_check_constraint :sign_in_links, name: "sign_in_links_kind"
    add_check_constraint :sign_in_links, expression, name: "sign_in_links_kind"
  end
end
