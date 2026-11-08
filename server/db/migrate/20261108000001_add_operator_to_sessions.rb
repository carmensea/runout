# A session opened through the operator's sign-in-as link (bin/rails auth:sign_in_as): it sees the
# account as its owner does, except that memory text is replaced with placeholder words and
# memories cannot be written (docs/milestone-5-plan.md §4.5).
class AddOperatorToSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :sessions, :operator, :boolean, default: false, null: false
  end
end
