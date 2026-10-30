ENV["RAILS_ENV"] ||= "test"
# Fixed, fake Last.fm credentials. Tests stub every HTTP call, so nothing reaches Last.fm.
ENV["LASTFM_API_KEY"] = "test-api-key"
ENV["LASTFM_SHARED_SECRET"] = "test-shared-secret"
ENV["APP_ORIGIN"] = "http://localhost:5173"
ENV["LASTFM_MIN_REQUEST_INTERVAL"] = "0"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"
Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

WebMock.disable_net_connect!

module ActiveSupport
  class TestCase
    parallelize(workers: :number_of_processors)

    # Synthetic Last.fm responses (https://www.last.fm/api/show/auth.getSession, user.getInfo).
    module LastfmStubs
      API = "https://ws.audioscrobbler.com/2.0/".freeze

      def stub_lastfm(method, body:, status: 200)
        stub_request(:get, API).with(query: hash_including("method" => method))
          .to_return(status: status, body: body.is_a?(String) ? body : body.to_json, headers: { "Content-Type" => "application/json" })
      end

      def stub_get_session(username:, key: "session-key-#{username}")
        stub_lastfm("auth.getSession", body: { session: { name: username, key: key, subscriber: 0 } })
      end

      # Shaped like Last.fm's live response (checked 2026-10-29): no numeric id field.
      # `registered: nil` simulates a response without a registration time.
      def stub_user_info(username:, registered: 1199145600)
        user = { name: username, url: "https://www.last.fm/user/#{username}", playcount: "0" }
        user[:registered] = { unixtime: registered.to_s, "#text" => registered } if registered
        stub_lastfm("user.getInfo", body: { user: user })
      end

      def stub_lastfm_error(method, code:, message: "error", status: 200)
        stub_lastfm(method, body: { error: code, message: message }, status: status)
      end
    end

    include LastfmStubs

    # Single-account mode with "listener" unless a test says otherwise (Lastfm::AccountPolicy).
    setup { allow_lastfm_accounts("listener") }

    # Retries still happen in tests, but without real sleeps.
    setup { Rails.configuration.x.lastfm_client_options = { sleeper: ->(_seconds) { } } }

    # Tests without the transactional wrapper run real threads. Rails wraps each test in the
    # executor, which turns the query cache on for the test's own thread, and a write clears only
    # the writing thread's cache. So once worker threads had written, repeating a query here
    # returned the result cached before they ran (a "missing" play that was in fact stored).
    # These tests read the database directly.
    setup { ActiveRecord::Base.connection_pool.disable_query_cache! unless use_transactional_tests }

    # A client for unit tests: no pacer, no sleeping. Override anything per test.
    def stub_client(**options)
      Lastfm::Client.new(api_key: "test-api-key", shared_secret: "test-shared-secret", sleeper: ->(_seconds) { }, **options)
    end

    def allow_lastfm_accounts(*usernames)
      Rails.configuration.x.lastfm_allowed_usernames = usernames
    end
  end
end

module SignInHelpers
  # Runs the full browser flow against stubbed Last.fm: start, then callback with the issued state.
  def sign_in_via_lastfm(username:, registered: 1199145600, tz: "Europe/London", token: "tok-#{SecureRandom.hex(4)}")
    stub_get_session(username: username)
    stub_user_info(username: username, registered: registered)
    get "/api/auth/lastfm", params: { tz: tz }
    state = Rack::Utils.parse_query(URI(Rack::Utils.parse_query(URI(response.location).query)["cb"]).query)["state"]
    get "/api/auth/lastfm/callback", params: { state: state, token: token }
    response
  end

  def session_cookie
    cookies[Authentication::COOKIE_NAME]
  end

  def same_origin_headers
    { "Origin" => "http://localhost:5173", "X-Requested-With" => "XMLHttpRequest" }
  end
end

class ActionDispatch::IntegrationTest
  include SignInHelpers
end
