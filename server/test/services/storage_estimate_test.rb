require "test_helper"

class StorageEstimateTest < ActiveSupport::TestCase
  test "measures a synthetic history and leaves nothing behind" do
    lines = StorageEstimate.run(scrobbles: 500)
    assert(lines.any? { |line| line.start_with?("scrobbles") && line.include?("500 rows") })
    assert(lines.last.include?("bytes per scrobble"))
    assert_equal 0, Scrobble.count + NameVariant.count + Artist.count + ImportWindow.count
    assert_not User.exists?(display_name: "storage-estimate")
  end

  test "refuses to run where history tables already hold data" do
    Rails.configuration.x.history_import_enabled = "true"
    Artist.create!(name: "Existing")
    assert_raises(RuntimeError) { StorageEstimate.run(scrobbles: 10) }
    assert Artist.exists?(name: "Existing"), "nothing was truncated"
  ensure
    Rails.configuration.x.history_import_enabled = "false"
  end
end
