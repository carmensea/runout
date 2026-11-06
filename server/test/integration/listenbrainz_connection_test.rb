require "test_helper"

# Connecting a ListenBrainz account (docs/listenbrainz-spotify-feasibility.md §5 PR A, §8): the token
# is checked once with ListenBrainz and discarded; the verified username is bound to the signed-in
# account; one ListenBrainz account per Runout user; disconnecting keeps what was recorded;
# nothing works while the flag is off. ListenBrainz is stubbed.
class ListenbrainzConnectionTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  VALIDATE = "https://api.listenbrainz.org/1/validate-token".freeze

  setup do
    @flag = Rails.configuration.x.listenbrainz_ingestion_enabled
    Rails.configuration.x.listenbrainz_ingestion_enabled = "true"
  end
  teardown { Rails.configuration.x.listenbrainz_ingestion_enabled = @flag }

  def json = response.parsed_body

  def stub_validate(token, user_name: nil)
    body = user_name ? { code: 200, message: "Token valid.", valid: true, user_name: user_name } : { code: 200, message: "Token invalid.", valid: false }
    stub_request(:get, VALIDATE).with(headers: { "Authorization" => "Token #{token}" })
                                .to_return(status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" })
  end

  def invite!(name)
    user = User.create!(display_name: name, reporting_timezone: "UTC")
    _, token = Session.start!(user: user, ip_address: "127.0.0.1", user_agent: "test")
    [ user, token ]
  end

  def connect(token)
    post "/api/listening-sources/listenbrainz", params: { token: token }, headers: same_origin_headers, as: :json
  end

  test "a valid token binds the ListenBrainz username and is not kept; the response and the source carry no token" do
    _, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    stub_validate("lb-secret-token", user_name: "dana_lb")

    connect("lb-secret-token")
    assert_response :ok
    assert_equal({ "enabled" => true, "state" => "connected", "account" => { "id" => "dana_lb", "displayName" => "dana_lb" } },
                 json["listenbrainz"].slice("enabled", "state", "account"))
    assert_not_includes response.body, "lb-secret-token"
    source = ListeningSource.find_by!(provider: "listenbrainz", external_account_id: "dana_lb")
    assert_nil source.credentials, "the token is discarded after verification"
    assert_requested(:get, VALIDATE, headers: { "User-Agent" => Listenbrainz::Client.user_agent })
    assert_equal "[FILTERED]", ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter("token" => "lb-secret-token")["token"], "the request parameter never reaches the logs"
  end

  test "an invalid token, an empty token, and the flag being off are refused without creating anything" do
    _, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    stub_validate("bad-token")
    connect("bad-token")
    assert_equal [ 422, "invalid_token" ], [ response.status, json["error"] ]
    assert_requested(:get, VALIDATE, headers: { "Authorization" => "Token bad-token" })
    connect("")
    assert_equal [ 422, "invalid_token" ], [ response.status, json["error"] ]
    Rails.configuration.x.listenbrainz_ingestion_enabled = "false"
    connect("whatever")
    assert_equal [ 409, "ingestion_disabled" ], [ response.status, json["error"] ]
    assert_equal 0, ListeningSource.count
    assert_not_requested(:get, VALIDATE, headers: { "Authorization" => "Token whatever" })
  end

  test "one ListenBrainz account belongs to one Runout user; the other sees only their own sources" do
    _, dana = invite!("Dana")
    _, erin = invite!("Erin")
    stub_validate("dana-token", user_name: "shared_lb")
    stub_validate("erin-token", user_name: "shared_lb")
    cookies[Authentication::COOKIE_NAME] = dana
    connect("dana-token")
    assert_response :ok
    before = ListeningSource.sole.attributes

    cookies[Authentication::COOKIE_NAME] = erin
    connect("erin-token")
    assert_equal [ 409, "account_taken" ], [ response.status, json["error"] ]
    assert_equal before, ListeningSource.sole.attributes, "dana's source is untouched"
    get "/api/listening-sources"
    assert_equal "not_connected", json.dig("listenbrainz", "state")
    assert_nil json.dig("listenbrainz", "account")
  end

  test "disconnecting keeps the plays; reconnecting reuses the same source" do
    dana, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    stub_validate("lb-token-1", user_name: "dana_lb")
    connect("lb-token-1")
    source = ListeningSource.sole
    play = ListeningStorage.writing_for("listenbrainz") { scrobble(dana, at: Time.utc(2026, 11, 1, 12), variant: variant(track: "Kept", artist: "Band")) }
    play.update!(source: "listenbrainz")
    ListeningStorage.writing_for("listenbrainz") do
      ListeningObservation.create!(user: dana, listening_source: source, provider: "listenbrainz", source_event_id: "1:abc", reported_at: play.played_at,
                                   reported_at_raw: "1793534400", timestamp_kind: "listen_started_at", name_variant: play.name_variant,
                                   scrobble: play, link_state: "created", received_at: Time.current, last_seen_at: Time.current)
    end

    post "/api/listening-sources/listenbrainz/disconnect", headers: same_origin_headers
    assert_response :ok
    assert_equal "disconnected", json.dig("listenbrainz", "state")
    assert_equal "disconnected", source.reload.state
    assert Scrobble.exists?(play.id), "plays already stored stay"
    assert_equal 1, ListeningObservation.where(listening_source: source).count

    post "/api/listening-sources/listenbrainz/disconnect", headers: same_origin_headers
    assert_response :not_found

    stub_validate("lb-token-2", user_name: "dana_lb")
    connect("lb-token-2")
    assert_response :ok
    assert_equal 1, ListeningSource.count, "the same source, reconnected"
    assert_equal [ "connected", nil ], source.reload.values_at(:state, :disconnected_at)
    assert_nil source.credentials
  end

  test "ListenBrainz being rate limited or down is reported as such, never as the user's fault" do
    _, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    stub_request(:get, VALIDATE).to_return(status: 429, headers: { "Retry-After" => "30" }, body: "")
    connect("lb-token-x")
    assert_equal [ 429, "rate_limited" ], [ response.status, json["error"] ]
    assert json["retryAfter"].present?
    stub_request(:get, VALIDATE).to_return(status: 503, body: "")
    connect("lb-token-x")
    assert_equal [ 503, "unavailable" ], [ response.status, json["error"] ]
    assert_equal 0, ListeningSource.count
  end

  test "connection attempts are rate limited per address, ten a minute" do
    _, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    stub_validate("lb-token-bad")
    10.times { connect("lb-token-bad") }
    assert_equal 422, response.status, "ten attempts are allowed"
    connect("lb-token-bad")
    assert_equal 429, response.status
    travel 61.seconds do
      connect("lb-token-bad")
      assert_equal 422, response.status, "the window has passed"
    end
  end

  test "a token that is not shaped like one is refused before anything is sent" do
    _, session = invite!("Dana")
    cookies[Authentication::COOKIE_NAME] = session
    connect("bad\r\nX-Injected: 1")
    assert_equal [ 422, "invalid_token" ], [ response.status, json["error"] ]
    connect("x" * 65)
    assert_equal [ 422, "invalid_token" ], [ response.status, json["error"] ]
    assert_not_requested(:get, VALIDATE)
  end
end
