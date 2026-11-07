# Music Diary (docs/milestone-5-plan.md §4, built as Memories): a user's own words about a song.
# One row per memory, owned by one user, attached to a catalogue track read through its merge
# chain; `remembered_on` and `remembered_label` say what time the memory is about, `created_at`
# when it was written. Private only: the check allows no other visibility until a later migration
# and its authorization exist. Deleted with the user; never deleted by catalogue changes (tracks
# are merged, not removed).
class CreateMemories < ActiveRecord::Migration[8.1]
  def change
    create_table :memories do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :track, null: false, foreign_key: { on_delete: :restrict }
      t.text :body, null: false
      t.date :remembered_on
      t.string :remembered_label
      t.string :visibility, null: false, default: "private"
      t.timestamps
    end
    add_index :memories, %i[user_id created_at]
    add_index :memories, %i[user_id remembered_on]
    add_check_constraint :memories, "visibility::text IN ('private')", name: "memories_visibility"
    add_check_constraint :memories, "length(body) BETWEEN 1 AND 20000", name: "memories_body_length"
  end
end
