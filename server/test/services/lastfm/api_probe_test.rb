require "test_helper"

class Lastfm::ApiProbeTest < ActiveSupport::TestCase
  setup do
    @client = stub_client(max_attempts: 1) # the probe never retries
    @fake = FakeRecentTracks.history(count: 450, same_second_every: nil).install(self)
    @sleeps = []
  end

  def probe(**options)
    Lastfm::ApiProbe.new(client: @client, username: "listener", sleeper: ->(s) { @sleeps << s }, **options).run
  end

  test "reports the verified live behaviour from the synthetic server" do
    findings = probe(session_key: "sk")

    assert findings[:a1_counts].values.all?, findings[:a1_counts].inspect
    assert findings[:a3_ordering][:newest_first_within_pages]
    assert findings[:a3_ordering][:historical_page_identical_on_second_read]
    assert_equal({ tested: true, from_is_inclusive: true, to_is_inclusive: false, from_equals_to_returns_the_play: false,
                   total_matches_rows_in_one_page_range: true }, findings[:a2_boundaries])
    assert_not findings[:pagination][:page_past_end_returns_rows]
    assert_equal({ rows: 0, total: 0, total_pages: 0 }, findings[:empty_range])
    assert findings[:a5_signed_matches_unsigned]
    assert_not findings[:rate_limited]
  end

  test "detects a different boundary rule instead of assuming one" do
    @fake.to_inclusive = true
    assert probe[:a2_boundaries][:to_is_inclusive]
  end

  test "sees the now-playing entry and does not count it" do
    @fake.now_playing = true
    findings = probe
    assert findings[:a4_now_playing][:present_on_page_1]
    assert findings[:a1_counts][:total_pages_consistent_at_200]
  end

  test "paces requests and stays within its budget" do
    findings = probe(budget: 20, interval: 1.25)
    assert_operator findings[:requests], :<=, 20
    assert_equal findings[:requests], @fake.requests
    assert_equal [ 1.25 ] * (findings[:requests] - 1), @sleeps
  end

  test "stops at the first rate-limit error without retrying" do
    @fake.rate_limit_after = 3
    findings = probe
    assert findings[:rate_limited]
    assert_equal 4, @fake.requests, "three answered requests, one rate-limited, no retry"
  end

  test "stops when the request budget runs out" do
    findings = probe(budget: 2)
    assert_equal 2, findings[:requests]
    assert_match(/budget/, findings[:note])
  end

  test "writes nothing to the database" do
    writes = []
    callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { probe(session_key: "sk") }
    assert_empty writes
  end
end
