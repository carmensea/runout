require "test_helper"

# Stage 2.2: retries, backoff, rate limits, error classification and secret handling, against
# synthetic responses. No network.
class Lastfm::ClientReliabilityTest < ActiveSupport::TestCase
  API = Lastfm::Client::API_URL.to_s

  class RecordingPacer
    attr_reader :reservations, :cool_downs

    def initialize
      @reservations = 0
      @cool_downs = []
    end

    def reserve! = @reservations += 1
    def cool_down!(seconds) = @cool_downs << seconds
  end

  setup do
    @sleeps = []
    @pacer = RecordingPacer.new
    @client = Lastfm::Client.new(api_key: "key-0123456789abcdef", shared_secret: "secret-fedcba9876543210",
                                 pacer: @pacer, sleeper: ->(s) { @sleeps << s }, random: Random.new(42),
                                 base_delay: 1.0, max_delay: 60.0, max_attempts: 4, max_retry_after: 300.0)
  end

  def stub_sequence(*responses)
    stub_request(:get, API).with(query: hash_including({})).to_return(*responses)
  end

  def ok_user = { status: 200, body: { user: { name: "listener" } }.to_json }

  test "retries transient server errors with exponential backoff and full jitter, then succeeds" do
    stub_sequence({ status: 502, body: "Bad Gateway" }, { status: 503, body: "" }, ok_user)
    assert_equal "listener", @client.user_info(session_key: "sk-1")[:username]
    assert_equal 2, @sleeps.size
    assert @sleeps[0].between?(0, 1.0), "attempt 1 waits up to base_delay"
    assert @sleeps[1].between?(0, 2.0), "attempt 2 waits up to 2 x base_delay"
    assert_equal 3, @pacer.reservations, "every attempt reserves a paced slot"
  end

  test "retries are bounded" do
    stub_sequence({ status: 500, body: "" })
    error = assert_raises(Lastfm::Error::Temporary) { @client.user_info(session_key: "sk-1") }
    assert_equal 500, error.http_status
    assert_requested :get, API, query: hash_including({}), times: 4
    assert_equal 3, @sleeps.size
  end

  test "timeouts and connection failures are transient and retried" do
    stub_request(:get, API).with(query: hash_including({}))
      .to_timeout.then.to_raise(Errno::ECONNREFUSED).then.to_raise(Errno::ECONNRESET).then.to_return(ok_user)
    assert_equal "listener", @client.user_info(session_key: "sk-1")[:username]
    assert_equal 3, @sleeps.size
  end

  test "HTTP 429 honours a Retry-After in seconds and cools everyone down" do
    stub_sequence({ status: 429, body: "Too Many Requests", headers: { "Retry-After" => "7" } }, ok_user)
    @client.user_info(session_key: "sk-1")
    assert_equal [ 7.0 ], @sleeps
    assert_equal [ 7.0 ], @pacer.cool_downs, "a rate limit pauses all processes, not only this one"
  end

  test "Retry-After as an HTTP date is honoured" do
    later = (Time.now + 20).httpdate
    stub_sequence({ status: 503, body: "", headers: { "Retry-After" => later } }, ok_user)
    @client.user_info(session_key: "sk-1")
    assert @sleeps.sole.between?(15, 21), @sleeps.inspect
  end

  test "a Retry-After longer than we will wait raises at once instead of blocking" do
    stub_sequence({ status: 429, body: "", headers: { "Retry-After" => "3600" } })
    error = assert_raises(Lastfm::Error::RateLimited) { @client.user_info(session_key: "sk-1") }
    assert_equal 3600.0, error.retry_after
    assert_empty @sleeps
    assert_requested :get, API, query: hash_including({}), times: 1
  end

  test "Last.fm error 29 is a rate limit: longer backoff and a global cool-down" do
    stub_sequence({ status: 200, body: { error: 29, message: "Rate Limit Exceeded" }.to_json }, ok_user)
    @client.user_info(session_key: "sk-1")
    assert_equal 1, @pacer.cool_downs.size
    assert @sleeps.sole.between?(0, 4.0), "rate limits back off from 4 x base_delay"
  end

  test "Last.fm's temporary errors 8, 11 and 16 are retried" do
    [ 8, 11, 16 ].each do |code|
      WebMock.reset!
      stub_sequence({ status: 200, body: { error: code, message: "temporary" }.to_json }, ok_user)
      assert_equal "listener", @client.user_info(session_key: "sk-1")[:username], "error #{code}"
    end
  end

  test "permanent errors are never retried" do
    { 4 => Lastfm::Error::TokenRejected, 6 => Lastfm::Error::RequestRejected, 9 => Lastfm::Error::InvalidSessionKey,
      10 => Lastfm::Error::ApiKeyRejected, 26 => Lastfm::Error::ApiKeyRejected }.each do |code, klass|
      WebMock.reset!
      stub_sequence({ status: 200, body: { error: code, message: "permanent" }.to_json })
      assert_raises(klass) { @client.user_info(session_key: "sk-1") }
      assert_requested :get, API, query: hash_including({}), times: 1
    end
    assert_empty @sleeps
  end

  test "a non-JSON 4xx is rejected without retrying" do
    stub_sequence({ status: 403, body: "<html>Forbidden</html>" })
    assert_raises(Lastfm::Error::RequestRejected) { @client.user_info(session_key: "sk-1") }
    assert_requested :get, API, query: hash_including({}), times: 1
  end

  test "a non-JSON error page with a 5xx status is transient" do
    stub_sequence({ status: 504, body: "<html>Gateway Timeout</html>" }, ok_user)
    assert_equal "listener", @client.user_info(session_key: "sk-1")[:username]
  end

  test "a truncated 200 body is unparseable and retried, then reported" do
    stub_sequence({ status: 200, body: '{"recenttracks": {"track": [' })
    assert_raises(Lastfm::Error::Unparseable) { @client.recent_tracks(username: "listener") }
    assert_requested :get, API, query: hash_including({}), times: 4
  end

  test "valid JSON missing required data is permanent" do
    stub_sequence({ status: 200, body: { unexpected: true }.to_json })
    assert_raises(Lastfm::Error::BadResponse) { @client.user_info(session_key: "sk-1") }
    assert_requested :get, API, query: hash_including({}), times: 1
  end

  test "the single-use sign-in token is never retried, even after a timeout" do
    stub_request(:get, API).with(query: hash_including({})).to_timeout
    assert_raises(Lastfm::Error::Temporary) { @client.get_session("single-use-token") }
    assert_requested :get, API, query: hash_including({}), times: 1
  end

  test "transient versus permanent is explicit on every error" do
    assert Lastfm::Error::Temporary.new.retryable?
    assert Lastfm::Error::RateLimited.new.retryable?
    assert Lastfm::Error::Unparseable.new.retryable?
    [ Lastfm::Error::BadResponse, Lastfm::Error::RequestRejected, Lastfm::Error::TokenRejected,
      Lastfm::Error::InvalidSessionKey, Lastfm::Error::ApiKeyRejected ].each { |klass| assert_not klass.new.retryable?, klass.name }
  end

  test "credentials never appear in error messages, even when Last.fm echoes them back" do
    echo = "Invalid session key-sk-1 for key-0123456789abcdef (secret-fedcba9876543210)"
    stub_sequence({ status: 200, body: { error: 9, message: echo }.to_json })
    error = assert_raises(Lastfm::Error::InvalidSessionKey) { @client.user_info(session_key: "sk-1") }
    [ "sk-1", "key-0123456789abcdef", "secret-fedcba9876543210" ].each do |secret|
      assert_not_includes error.message, secret
      assert_not_includes error.inspect, secret
    end
    assert_includes error.message, "[REDACTED]"
  end

  test "network errors report the failure type, never the request URL" do
    stub_request(:get, API).with(query: hash_including({})).to_raise(SocketError.new("getaddrinfo failed for https://ws.audioscrobbler.com/2.0/?api_key=key-0123456789abcdef&sk=sk-1"))
    error = assert_raises(Lastfm::Error::Temporary) { @client.user_info(session_key: "sk-1") }
    assert_equal "Last.fm could not be reached (SocketError)", error.message
  end

  test "inspecting the client never shows the API key or shared secret" do
    [ @client.inspect, @client.to_s ].each do |text|
      assert_not_includes text, "key-0123456789abcdef"
      assert_not_includes text, "secret-fedcba9876543210"
    end
  end

  test "the recent-tracks reader keeps exact strings and same-second duplicates through retries" do
    page = { recenttracks: { "@attr" => { page: "1", perPage: "200", totalPages: "1", total: "2" },
                             track: Array.new(2) { { artist: { mbid: "", "#text" => " Artist " }, name: "Track", mbid: "",
                                                     album: { mbid: "", "#text" => "" }, date: { uts: "1393286400" } } } } }
    stub_sequence({ status: 503, body: "" }, { status: 200, body: page.to_json })
    result = @client.recent_tracks(username: "listener")
    assert_equal 2, result.scrobbles.size
    assert_equal " Artist ", result.scrobbles.first.artist
  end
end
