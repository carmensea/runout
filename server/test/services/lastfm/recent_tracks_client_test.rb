require "test_helper"

class Lastfm::RecentTracksClientTest < ActiveSupport::TestCase
  setup do
    @client = Lastfm::Client.new(api_key: "test-api-key", shared_secret: "test-shared-secret")
    @fake = FakeRecentTracks.history(count: 450).install(self)
  end

  test "sends from and to as Unix seconds, with paging parameters" do
    from = Time.utc(2020, 5, 31)
    to = Time.utc(2020, 6, 1)
    @client.recent_tracks(username: "listener", page: 2, limit: 100, from: from, to: to)

    assert_requested(:get, %r{audioscrobbler}) do |req|
      q = Rack::Utils.parse_query(req.uri.query)
      q["method"] == "user.getRecentTracks" && q["user"] == "listener" && q["page"] == "2" && q["limit"] == "100" &&
        q["from"] == from.to_i.to_s && q["to"] == to.to_i.to_s && !q.key?("sk") && !q.key?("api_sig") && !q.key?("extended")
    end
  end

  test "signs the request when a session key is given" do
    @client.recent_tracks(username: "listener", session_key: "sk-1")
    assert_requested(:get, %r{audioscrobbler}) { |req| Rack::Utils.parse_query(req.uri.query).values_at("sk", "api_sig").all?(&:present?) }
  end

  test "refuses limits outside 1..200" do
    assert_raises(ArgumentError) { @client.recent_tracks(username: "listener", limit: 201) }
    assert_raises(ArgumentError) { @client.recent_tracks(username: "listener", limit: 0) }
  end

  test "paging by totalPages visits every play exactly once" do
    first = @client.recent_tracks(username: "listener", limit: 200)
    plays = (1..first.total_pages).flat_map { |n| @client.recent_tracks(username: "listener", limit: 200, page: n).scrobbles }
    assert_equal first.total, plays.size
    assert_equal 450, plays.size
  end

  test "half-open ranges [from, to) split history without gaps or overlaps" do
    middle = Time.utc(2020, 6, 1, 10)
    newer = @client.recent_tracks(username: "listener", from: middle).scrobbles
    older = @client.recent_tracks(username: "listener", to: middle, limit: 200, page: 1)
    older_rows = (1..older.total_pages).flat_map { |n| @client.recent_tracks(username: "listener", to: middle, page: n).scrobbles }
    assert_equal 450, newer.size + older_rows.size
    assert newer.all? { |s| s.played_at >= middle }
    assert older_rows.all? { |s| s.played_at < middle }
  end

  test "a page past the end returns no rows" do
    last = @client.recent_tracks(username: "listener", limit: 200).total_pages
    assert_equal 3, last
    assert_empty @client.recent_tracks(username: "listener", limit: 200, page: last + 1).scrobbles
  end
end
