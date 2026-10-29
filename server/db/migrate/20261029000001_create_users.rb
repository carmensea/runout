class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users, id: :uuid do |t|
      t.string :display_name, null: false
      # IANA zone used for all local-time bucketing (docs/backend-plan.md §7).
      t.string :reporting_timezone, null: false, default: "UTC"
      t.timestamps
    end
  end
end
