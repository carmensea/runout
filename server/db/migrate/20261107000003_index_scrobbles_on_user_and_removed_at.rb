# Analytics::HistoryVersion asks, per request, when a user's plays were last removed. Removed plays
# are few, so a partial index keeps that a lookup instead of a walk over every play of the user.
class IndexScrobblesOnUserAndRemovedAt < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :scrobbles, %i[user_id removed_at], where: "removed_at IS NOT NULL", algorithm: :concurrently
  end
end
