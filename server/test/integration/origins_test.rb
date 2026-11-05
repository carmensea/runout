require "test_helper"

# Several hostnames at once while the domain changes (docs/railway-deployment.md §10): APP_ORIGINS
# is allowed, state-changing requests stay strictly same-origin, and Last.fm sign-in moves to the
# canonical origin first because cookies are per host.
class OriginsTest < ActionDispatch::IntegrationTest
  OLD = "http://localhost:5173".freeze
  NEW = "http://runout.test".freeze

  def with_origins(canonical, *others)
    before = [ Rails.configuration.x.app_origin, Rails.configuration.x.app_origins ]
    Rails.configuration.x.app_origin = canonical
    Rails.configuration.x.app_origins = [ canonical, *others ]
    yield
  ensure
    Rails.configuration.x.app_origin, Rails.configuration.x.app_origins = before
  end

  def write(host, origin)
    host! URI(host).host.then { |h| URI(host).port == 80 ? h : "#{h}:#{URI(host).port}" }
    delete "/api/session", headers: { "Origin" => origin, "X-Requested-With" => "XMLHttpRequest" }
    response.status
  end

  test "APP_ORIGIN alone keeps the single-origin behaviour" do
    assert_equal [ "https://a.example" ], Runout::Origins.list({ "APP_ORIGIN" => "https://a.example" })
    assert_equal [ "a.example" ], Runout::Origins.hosts({ "APP_ORIGIN" => "https://a.example" })
    assert_equal [ OLD ], Runout::Origins.list({})
  end

  test "APP_ORIGINS adds hostnames after the canonical one, without duplicates" do
    env = { "APP_ORIGIN" => "https://new.example", "APP_ORIGINS" => " https://old.example, https://new.example ," }
    assert_equal %w[https://new.example https://old.example], Runout::Origins.list(env)
    assert_equal %w[new.example old.example], Runout::Origins.hosts(env)
  end

  test "host authorization (production) admits only the configured hostnames" do
    hosts = Runout::Origins.hosts({ "APP_ORIGIN" => "https://new.example", "APP_ORIGINS" => "https://old.example" })
    middleware = ActionDispatch::HostAuthorization.new(->(_env) { [ 200, {}, [ "ok" ] ] }, hosts)
    %w[new.example old.example].each do |host|
      assert_equal 200, middleware.call(Rack::MockRequest.env_for("/api/connection", "HTTP_HOST" => host)).first, host
    end
    %w[evil.example sub.new.example new.example.evil].each do |host|
      assert_equal 403, middleware.call(Rack::MockRequest.env_for("/api/connection", "HTTP_HOST" => host)).first, host
    end
  end

  test "a signed-in session on the old hostname keeps working after the canonical origin moves" do
    sign_in_via_lastfm(username: "listener")
    with_origins(NEW, OLD) do
      get "/api/connection"
      assert_equal "connected", response.parsed_body["status"]
      assert_equal 204, write(OLD, OLD)
    end
    assert_equal 0, Session.count
  end

  test "the session does not cross to the other hostname" do
    sign_in_via_lastfm(username: "listener")
    with_origins(NEW, OLD) do
      host! "runout.test"
      get "/api/connection"
      assert_equal({ "status" => "signed_out" }, response.parsed_body)
    end
  end

  test "a write must carry the Origin of the hostname it is sent to, even among configured ones" do
    sign_in_via_lastfm(username: "listener")
    with_origins(NEW, OLD) do
      assert_equal 403, write(OLD, NEW), "cross-host, both configured"
      assert_equal 403, write(NEW, OLD), "cross-host, the other way"
      assert_equal 403, write(OLD, "https://evil.example"), "unknown origin"
      assert_equal 403, write(OLD, "http://localhost:5173.evil.example"), "prefix of a configured origin"
    end
    with_origins(OLD) do
      assert_equal 403, write(OLD, NEW), "an origin that is no longer configured"
    end
    assert_equal 1, Session.count
  end

  test "Last.fm sign-in started on another configured hostname moves to the canonical origin first" do
    with_origins(NEW, OLD) do
      get "/api/auth/lastfm", params: { tz: "Europe/London" }
      assert_redirected_to "#{NEW}/api/auth/lastfm?tz=Europe%2FLondon"
      assert_nil cookies[Api::LastfmAuthController::STATE_COOKIE.to_s], "no state cookie on the old hostname"

      host! "runout.test"
      sign_in_via_lastfm(username: "listener")
      assert_redirected_to "/overview"
      assert_includes request.original_url, "/api/auth/lastfm/callback"
      assert_equal "runout.test", request.host
      get "/api/connection"
      assert_equal "connected", response.parsed_body["status"]
    end
  end

  test "Last.fm sign-in on the canonical origin, or an unconfigured host, does not redirect" do
    with_origins(NEW, OLD) do
      host! "runout.test"
      get "/api/auth/lastfm"
      assert_includes response.location, "last.fm/api/auth"
      host! "www.example.com"
      get "/api/auth/lastfm"
      assert_includes response.location, "last.fm/api/auth"
    end
  end
end
