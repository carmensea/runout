require "test_helper"

class HistoryImportTest < ActiveSupport::TestCase
  setup { @original = Rails.configuration.x.history_import_enabled }
  teardown { Rails.configuration.x.history_import_enabled = @original }

  test "is off by default" do
    assert_nil ENV["LASTFM_HISTORY_STORAGE_ENABLED"], "the test environment must not set the flag"
    assert_equal "false", Rails.configuration.x.history_import_enabled
    assert_not HistoryImport.enabled?
  end

  test "only an explicit true or 1 enables it" do
    { "true" => true, "1" => true, " TRUE " => true, "false" => false, "0" => false, "yes" => false, "" => false, nil => false }.each do |value, expected|
      Rails.configuration.x.history_import_enabled = value
      assert_equal expected, HistoryImport.enabled?, "value #{value.inspect}"
    end
  end

  test "ensure_enabled! refuses while disabled" do
    Rails.configuration.x.history_import_enabled = "false"
    assert_raises(HistoryImport::DisabledError) { HistoryImport.ensure_enabled! }

    Rails.configuration.x.history_import_enabled = "true"
    assert_nil HistoryImport.ensure_enabled!
  end
end
