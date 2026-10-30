require "test_helper"

class Lastfm::ClientTest < ActiveSupport::TestCase
  setup do
    @client = stub_client
  end

  test "signs parameters as documented: sorted name+value pairs, then the secret, MD5" do
    expected = Digest::MD5.hexdigest("api_keytest-api-keymethodauth.getSessiontokenabc123test-shared-secret")
    assert_equal expected, @client.signature("token" => "abc123", "method" => "auth.getSession", "api_key" => "test-api-key")
  end

  test "excludes format and callback from the signature" do
    base = { "api_key" => "k", "method" => "m" }
    assert_equal @client.signature(base), @client.signature(base.merge("format" => "json", "callback" => "cb"))
  end

  test "builds the authorization URL with the callback" do
    url = URI(@client.authorization_url("http://localhost:5173/api/auth/lastfm/callback?state=xyz"))
    assert_equal "www.last.fm", url.host
    query = Rack::Utils.parse_query(url.query)
    assert_equal "test-api-key", query["api_key"]
    assert_equal "http://localhost:5173/api/auth/lastfm/callback?state=xyz", query["cb"]
  end

  test "get_session sends a signed request and returns the username and key" do
    stub = stub_get_session(username: "listener", key: "sk-1")
    result = @client.get_session("tok")
    assert_equal({ username: "listener", session_key: "sk-1" }, result)
    assert_requested(:get, %r{\Ahttps://ws\.audioscrobbler\.com/2\.0/}) do |req|
      q = Rack::Utils.parse_query(req.uri.query)
      q["api_sig"] == @client.signature(q.except("api_sig")) && q["format"] == "json" && q["token"] == "tok"
    end
    assert_requested stub
  end

  test "user_info asks about the session's own account, without a user parameter" do
    stub_user_info(username: "listener")
    info = @client.user_info(session_key: "sk-1")
    assert_equal "listener", info[:username]
    assert_equal Time.at(1199145600).utc, info[:registered_at]
    assert_requested(:get, %r{\Ahttps://ws\.audioscrobbler\.com/2\.0/}) do |req|
      q = Rack::Utils.parse_query(req.uri.query)
      q["method"] == "user.getInfo" && q["sk"] == "sk-1" && !q.key?("user") && q["api_sig"].present?
    end
  end

  test "user_info matches Last.fm's live shape: no id field, registration time optional" do
    stub_lastfm("user.getInfo", body: { user: { name: "listener", url: "https://www.last.fm/user/listener" } })
    info = @client.user_info(session_key: "sk")
    assert_not info.key?(:id)
    assert_nil info[:registered_at]
  end

  test "user_info rejects a response without a username" do
    stub_lastfm("user.getInfo", body: { user: { registered: { unixtime: "1199145600" } } })
    assert_raises(Lastfm::Error::BadResponse) { @client.user_info(session_key: "sk") }
  end

  test "public_user_info looks up a username without signing" do
    stub_user_info(username: "listener")
    assert_equal "listener", @client.public_user_info("listener")[:username]
    assert_requested(:get, %r{\Ahttps://ws\.audioscrobbler\.com/2\.0/}) do |req|
      q = Rack::Utils.parse_query(req.uri.query)
      q["user"] == "listener" && !q.key?("sk") && !q.key?("api_sig")
    end
  end

  test "maps Last.fm error codes to typed errors" do
    {
      4 => Lastfm::Error::TokenRejected, 14 => Lastfm::Error::TokenRejected, 15 => Lastfm::Error::TokenRejected,
      9 => Lastfm::Error::InvalidSessionKey, 10 => Lastfm::Error::ApiKeyRejected, 26 => Lastfm::Error::ApiKeyRejected,
      29 => Lastfm::Error::RateLimited, 11 => Lastfm::Error::Temporary, 6 => Lastfm::Error::RequestRejected
    }.each do |code, klass|
      WebMock.reset!
      stub_lastfm_error("auth.getSession", code: code, status: code == 29 ? 429 : 200)
      error = assert_raises(klass) { @client.get_session("tok") }
      assert_equal code, error.code
    end
  end

  test "rate limiting and temporary failures are retryable; rejections are not" do
    assert Lastfm::Error::RateLimited.new.retryable?
    assert Lastfm::Error::Temporary.new.retryable?
    assert_not Lastfm::Error::TokenRejected.new.retryable?
    assert_not Lastfm::Error::InvalidSessionKey.new.retryable?
  end

  test "server errors and timeouts become temporary errors" do
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_return(status: 503, body: "Service Unavailable")
    assert_raises(Lastfm::Error::Temporary) { @client.get_session("tok") }

    WebMock.reset!
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_timeout
    assert_raises(Lastfm::Error::Temporary) { @client.get_session("tok") }
  end

  test "HTTP 429 without a Last.fm error body is rate limiting" do
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_return(status: 429, body: "Too Many Requests")
    assert_raises(Lastfm::Error::RateLimited) { @client.get_session("tok") }
  end

  test "any network failure is temporary, never an unhandled error" do
    [ EOFError, Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Net::HTTPBadResponse ].each do |failure|
      WebMock.reset!
      stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_raise(failure)
      assert_raises(Lastfm::Error::Temporary, failure.name) { @client.get_session("tok") }
    end
  end

  test "a 200 response that is not JSON is retryable, then reported as unparseable" do
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_return(status: 200, body: "<html>")
    assert_raises(Lastfm::Error::Unparseable) { @client.user_info(session_key: "sk") }
  end
end
