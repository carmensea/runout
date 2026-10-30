require "test_helper"

class StorageScalabilityTest < ActiveSupport::TestCase
  include HistoryHelpers

  test "a user's date-range query can use the identity index" do
    user = history_user
    plan = ActiveRecord::Base.transaction(requires_new: true) do
      ActiveRecord::Base.connection.execute("SET LOCAL enable_seqscan = off")
      ActiveRecord::Base.connection.select_values(
        "EXPLAIN #{user.scrobbles.present.played_between(Time.utc(2014), Time.utc(2015)).to_sql}"
      ).join("\n")
    end
    assert_match(/index_scrobbles_identity/, plan)
  end

  test "the storage report includes the history tables" do
    assert_includes StorageReport::LASTFM_TABLES, "scrobbles"
    assert_includes StorageReport::LASTFM_TABLES, "import_window_rows"
    assert_includes StorageReport::LASTFM_TABLES, "name_variants"
  end
end
