# The theme the owner chose (docs/themes.md), so it follows the account between sign-ins and
# browsers. Nullable: nothing chosen yet keeps the browser's own choice. Additive only.
class AddThemeToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :theme, :string
  end
end
