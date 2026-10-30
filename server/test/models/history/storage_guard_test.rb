require "test_helper"

# No HistoryHelpers here: history storage stays at its default, off.
class StorageGuardTest < ActiveSupport::TestCase
  test "with history storage off, nothing derived from Last.fm history can be created" do
    assert_not HistoryImport.enabled?
    user = User.create!(display_name: "listener")
    [
      -> { NameVariant.for!(artist_name: "A", track_name: "T") },
      -> { Artist.create!(name: "A") },
      -> { ImportRun.create!(user: user, kind: "full") },
      -> { ImportWindow.create!(user: user, window_from: Time.utc(2014, 3, 1), window_to: Time.utc(2014, 4, 1)) }
    ].each { |create| assert_raises(HistoryImport::DisabledError) { create.call } }
    assert_equal 0, NameVariant.count + Artist.count + ImportRun.count + ImportWindow.count
  end

  test "every history model carries the guard" do
    [ Artist, Album, Track, NameVariant, ImportRun, ImportWindow, ImportWindowFetch, ImportWindowRow,
      Scrobble, ScrobbleCorrection, ScrobbleRemoval ].each do |model|
      assert_includes model.ancestors, HistoryStorage, model.name
    end
  end
end
