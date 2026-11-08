# Per-account feature flags (docs/milestone-5-plan.md §4.5 "Rollout"): names of the features an
# account can see, granted by hand with bin/rails features:grant. Empty for everyone by default.
class AddFeaturesToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :features, :string, array: true, default: [], null: false
  end
end
