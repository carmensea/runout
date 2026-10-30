require "test_helper"

class StorageReportTest < ActiveSupport::TestCase
  test "reports rows and on-disk size for each Last.fm-derived table" do
    user = User.create!(display_name: "listener")
    identity = user.identities.create!(provider: Identity::LASTFM, uid: "listener", username: "listener")
    user.create_lastfm_connection!(identity: identity)

    report = StorageReport.rows.index_by(&:table)
    assert_equal StorageReport::LASTFM_TABLES.sort, report.keys.sort
    assert_equal 1, report["identities"].rows
    assert_operator report["identities"].bytes, :>, 0
    assert_equal report.values.sum(&:bytes), StorageReport.total_bytes
  end
end
