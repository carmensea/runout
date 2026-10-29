ENV["RAILS_ENV"] ||= "test"
# Fixed, fake Last.fm credentials. Tests stub every HTTP call, so nothing reaches Last.fm.
ENV["LASTFM_API_KEY"] = "test-api-key"
ENV["LASTFM_SHARED_SECRET"] = "test-shared-secret"
ENV["APP_ORIGIN"] = "http://localhost:5173"

require_relative "../config/environment"
require "rails/test_help"
require "webmock/minitest"

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

      def stub_user_info(id:, username:)
        stub_lastfm("user.getInfo", body: {
          user: { id: id.to_s, name: username, url: "https://www.last.fm/user/#{username}",
                  registered: { unixtime: "1199145600", "#text" => 1199145600 }, playcount: "0" }
        })
      end

      def stub_lastfm_error(method, code:, message: "error", status: 200)
        stub_lastfm(method, body: { error: code, message: message }, status: status)
      end
    end

    include LastfmStubs
  end
end

module SignInHelpers
  # Runs the full browser flow against stubbed Last.fm: start, then callback with the issued state.
  def sign_in_via_lastfm(id:, username:, tz: "Europe/London", token: "tok-#{SecureRandom.hex(4)}")
    stub_get_session(username: username)
    stub_user_info(id: id, username: username)
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
