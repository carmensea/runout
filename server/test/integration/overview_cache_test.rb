require "test_helper"

# The Overview is computed once per user, period and state of the history, and served from the
# app's cache until that state changes (Analytics::HistoryVersion): a new play, a removal, a new
# cover or a catalogue change each produce a fresh answer, another account never sees this one's,
# and the browser is still told not to store it. Synthetic data only.
class OverviewCacheTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  setup do
    @store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    sign_in_via_lastfm(username: "listener")
    @user = User.sole
    scrobble(@user, at: Time.utc(2014, 3, 15, 20), variant: variant(track: "Song", artist: "Band", album: "Album"))
    Catalogue::Matcher.new.match!(NameVariant.sole)
  end

  teardown { Rails.cache = @store }

  # How many times the Overview was really computed inside the block.
  class << self
    attr_accessor :computations
  end
  self.computations = 0

  module Counted
    def call
      OverviewCacheTest.computations += 1
      super
    end
  end
  Analytics::Overview.prepend(Counted)

  def computed
    before = self.class.computations
    yield
    self.class.computations - before
  end

  test "the same period is computed once and served from the cache until a play changes the history" do
    assert_equal 1, computed { 3.times { get "/api/overview" } }
    assert_equal 1, response.parsed_body["stats"]["scrobbles"]
    assert_equal "no-store", response.headers["Cache-Control"], "the browser still never keeps it"

    assert_equal 1, computed { get "/api/overview", params: { period: "year:2014" } }, "another period is its own entry"
    assert_equal 0, computed { get "/api/overview", params: { period: "year:2014" } }

    scrobble(@user, at: Time.utc(2014, 3, 16, 20), variant: variant(track: "Song", artist: "Band", album: "Album"))
    assert_equal 1, computed { get "/api/overview" }, "a new play: computed afresh"
    assert_equal 2, response.parsed_body["stats"]["scrobbles"]
    assert_equal 0, computed { get "/api/overview" }
  end

  test "a removal, a new cover and a catalogue change each produce a fresh answer" do
    get "/api/overview"
    play = Scrobble.sole
    play.update!(removed_at: Time.current)
    get "/api/overview"
    assert_equal 0, response.parsed_body["stats"]["scrobbles"], "the removed play is gone from the answer"
    play.update!(removed_at: nil)
    get "/api/overview"
    assert_equal 1, response.parsed_body["stats"]["scrobbles"], "restored: the answer for that state again (cached from before or fresh, both right)"

    release = "11111111-1111-4111-8111-111111111111"
    Album.sole.update!(mbid: release)
    assert_equal 1, computed { get "/api/overview" }, "the catalogue album changed"
    MetadataArtwork.create!(provider: "coverartarchive", release_id: release, found_on: "release", image_id: "1",
                            thumbnail_250: "https://archive.org/1-250.jpg", source_url: "https://coverartarchive.org/release/#{release}", fetched_at: Time.current)
    assert_equal 1, computed { get "/api/overview" }, "a cover arrived"
    assert_equal "https://archive.org/1-250.jpg", response.parsed_body["top"]["albums"].first["imageUrl"]
    assert_equal 0, computed { get "/api/overview" }
  end

  test "covers for albums this user never played, and another account's plays, change nothing here" do
    get "/api/overview"
    MetadataArtwork.create!(provider: "coverartarchive", release_id: "22222222-2222-4222-8222-222222222222", found_on: "release", image_id: "2",
                            thumbnail_250: "https://archive.org/2-250.jpg", source_url: "https://coverartarchive.org/release/x", fetched_at: Time.current)
    other = User.create!(display_name: "other", reporting_timezone: "Europe/London")
    scrobble(other, at: Time.utc(2020, 1, 1, 12), variant: variant(track: "Else", artist: "Other", album: "Theirs"))
    Catalogue::Matcher.new.match!(NameVariant.find_by!(track_name: "Else"))
    assert_equal 0, computed { get "/api/overview" }, "an enrichment tick elsewhere and someone else's listening leave the cache useful"

    Album.find_by!(title: "Album").update!(mbid: "22222222-2222-4222-8222-222222222222")
    assert_equal 1, computed { get "/api/overview" }, "once this user's album resolves to that release, the cover is theirs"
    assert_equal "https://archive.org/2-250.jpg", response.parsed_body["top"]["albums"].first["imageUrl"]
  end

  test "another account never gets this one's answer, and a changed timezone is a new answer" do
    get "/api/overview"
    first = response.parsed_body
    @user.update!(reporting_timezone: "America/Los_Angeles")
    assert_equal 1, computed { get "/api/overview" }

    delete "/api/session", headers: same_origin_headers
    other = User.create!(display_name: "other", reporting_timezone: "Europe/London")
    _, token = Session.start!(user: other, ip_address: "127.0.0.1", user_agent: "test")
    cookies[Authentication::COOKIE_NAME] = token
    scrobble(other, at: Time.utc(2020, 1, 1, 12), variant: variant(track: "Else", artist: "Other", album: "Theirs"))
    assert_equal 1, computed { get "/api/overview" }
    assert_equal [ "Theirs" ], response.parsed_body["top"]["albums"].map { |a| a["name"] }
    assert_not_equal first, response.parsed_body
  end
end
