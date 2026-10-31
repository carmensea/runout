require "test_helper"

# Spotify, stage 2 (docs/spotify-plan.md §8): the client's error handling, connecting, token
# refresh and rotation, re-authorisation, disconnecting, the OAuth state, and mapping Recently
# Played items. Synthetic responses only (WebMock); nothing reaches Spotify.
class Spotify::AccountTest < ActiveSupport::TestCase
  include HistoryHelpers

  T = Time.utc(2026, 10, 31, 12)

  setup do
    @now = T
    @user = history_user
    @account = Spotify::Account.new(clock: -> { @now })
  end

  def connected!(user: @user, id: "spotify-user")
    stub_spotify_tokens
    stub_spotify_me(id: id)
    @account.connect!(user: user, code: "code-1")
  end

  def refresh_answer(access:, refresh: nil, status: 200, error: nil)
    body = error ? { error: error, error_description: "Refresh token revoked" } : { access_token: access, expires_in: 3600, scope: "user-read-recently-played", refresh_token: refresh }.compact
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end

  test "connecting stores the account and encrypted credentials, and sends the code with the app's own credentials" do
    source = connected!
    assert_equal [ "spotify", "spotify-user", "Listener", "connected", T ], source.values_at(:provider, :external_account_id, :display_name, :state, :connected_at)
    assert_equal({ "access_token" => "access-1", "refresh_token" => "refresh-1", "expires_at" => T.to_i + 3600 }, source.reload.credentials)
    raw = ListeningSource.connection.select_value("SELECT credentials FROM listening_sources WHERE id = #{source.id}")
    assert_not_includes raw, "access-1", "encrypted at rest"
    assert_not_includes raw, "refresh-1"
    assert_not_includes source.inspect, "access-1"
    assert_requested(:post, SpotifyStubs::TOKEN_URL, times: 1) do |req|
      form = Rack::Utils.parse_query(req.body)
      form == { "grant_type" => "authorization_code", "code" => "code-1", "redirect_uri" => "http://127.0.0.1:3000/api/auth/spotify/callback" } &&
        req.headers["Authorization"] == "Basic #{Base64.strict_encode64('test-spotify-client:test-spotify-secret')}"
    end
  end

  test "reconnecting the same account keeps its source; another user's account is refused; missing scope is refused" do
    first = connected!
    @account.disconnect!(first)
    assert_equal [ "disconnected", nil ], first.reload.values_at(:state, :credentials)
    @now = T + 1.day
    again = connected!
    assert_equal [ first.id, "connected", T + 1.day ], again.values_at(:id, :state, :connected_at)

    other = history_user("other")
    assert_raises(Spotify::Account::AccountTaken) { connected!(user: other) }

    stub_spotify_tokens(scope: "")
    assert_raises(Spotify::Account::InsufficientScope) { @account.connect!(user: other, code: "c") }
    assert_equal 1, ListeningSource.count
  end

  test "an expiring token is refreshed once, under a lock; a rotated refresh token is kept, otherwise the old one stays" do
    source = connected!
    assert_equal "access-1", @account.with_token(source) { |t| t }
    @now = T + 3600 - 60
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(refresh_answer(access: "access-2", refresh: "refresh-2"), refresh_answer(access: "access-3"))
    assert_equal "access-2", @account.with_token(source) { |t| t }
    assert_equal({ "access_token" => "access-2", "refresh_token" => "refresh-2", "expires_at" => @now.to_i + 3600 }, source.reload.credentials)
    assert_requested(:post, SpotifyStubs::TOKEN_URL) { |req| Rack::Utils.parse_query(req.body) == { "grant_type" => "refresh_token", "refresh_token" => "refresh-1" } }

    @now += 3600
    assert_equal "access-3", @account.with_token(source) { |t| t }
    assert_equal "refresh-2", source.reload.credentials["refresh_token"], "no new refresh token: keep the current one"
  end

  test "a 401 refreshes once and retries; a refused refresh token asks to connect again" do
    source = connected!
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(refresh_answer(access: "access-2"))
    tokens = []
    result = @account.with_token(source) do |t|
      tokens << t
      raise Spotify::Error::Unauthorized, "expired" if t == "access-1"

      :ok
    end
    assert_equal [ :ok, %w[access-1 access-2] ], [ result, tokens ]

    @now += 2.hours
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(refresh_answer(access: nil, status: 400, error: "invalid_grant"))
    assert_raises(Spotify::Account::NotConnected) { @account.with_token(source) { |t| t } }
    assert_equal [ "needs_reauth", nil ], source.reload.values_at(:state, :credentials)
    assert_match(/invalid_grant/, source.last_error)
    assert_raises(Spotify::Account::NotConnected) { @account.with_token(source) { |t| t } }
    assert_requested(:post, SpotifyStubs::TOKEN_URL, times: 3) # connect, the refused refresh, and nothing after it
  end

  test "the client maps 403, 429 with Retry-After, 5xx and network failures, without echoing tokens" do
    cooled = []
    pacer = Object.new.tap { |p| p.define_singleton_method(:reserve!) { }; p.define_singleton_method(:cool_down!) { |s| cooled << s } }
    client = Spotify::Client.new(pacer: pacer)
    url = %r{api\.spotify\.com/v1/me/player/recently-played}
    stub_request(:get, url).to_return(
      { status: 403, body: { error: { status: 403, message: "Insufficient client scope" } }.to_json },
      { status: 429, headers: { "Retry-After" => "17" }, body: { error: { status: 429, message: "API rate limit exceeded" }, reason: "QUOTA_EXCEEDED" }.to_json },
      { status: 502, body: "" }
    )
    e = assert_raises(Spotify::Error::Forbidden) { client.recently_played("secret-token") }
    assert_equal "Spotify answered HTTP 403: Insufficient client scope", e.message
    e = assert_raises(Spotify::Error::RateLimited) { client.recently_played("secret-token") }
    assert_equal [ 17, "QUOTA_EXCEEDED", [ 17 ] ], [ e.retry_after, e.reason, cooled ]
    assert_raises(Spotify::Error::Unavailable) { client.recently_played("secret-token") }
    stub_request(:get, url).to_timeout
    e = assert_raises(Spotify::Error::Unavailable) { client.recently_played("secret-token") }
    assert_not_includes e.message, "secret-token"
    assert_requested(:get, url, times: 4) { |req| req.headers["Authorization"] == "Bearer secret-token" }
    assert_raises(ArgumentError) { client.recently_played("t", before: 1, after: 2) }
  end

  test "the OAuth state names the user, expires after ten minutes, and can't be forged" do
    state, nonce = Spotify::OAuthState.issue(@user.id)
    assert_equal({ "u" => @user.id, "n" => nonce }, Spotify::OAuthState.read(state))
    assert_nil Spotify::OAuthState.read(state.reverse)
    assert_nil Spotify::OAuthState.read("")
    travel 11.minutes do
      assert_nil Spotify::OAuthState.read(state)
    end
  end

  test "a Recently Played item becomes an event: exact names, Spotify's IDs apart, the ISRC as an ISRC, milliseconds as the event ID" do
    e = Spotify::Mapping.event(spotify_item(T + 0.456, track: "Song", artist: "Band", album: "Album", duration: 201_000, id: "trk1"))
    assert_equal [ "spotify", (T.to_i * 1000 + 456).to_s, "2026-10-31T12:00:00.456Z", "spotify_played_at", 201_000 ],
                 [ e.provider, e.source_event_id, e.reported_at_raw, e.timestamp_kind, e.duration_ms ]
    assert_equal [ "Band", "Song", "Album", "trk1", "alb-Album", %w[art-Band art-feat], "GBAAA0000001" ],
                 [ e.artist_name, e.track_name, e.album_name, e.provider_track_id, e.provider_album_id, e.provider_artist_ids, e.isrc ]
    assert_equal({ "type" => "playlist", "uri" => "spotify:playlist:abc" }, e.context)

    local = spotify_item(T, id: nil).tap { |i| i["track"]["external_ids"] = {} }
    assert_nil Spotify::Mapping.event(local).provider_track_id, "a local file has no Spotify ID and is still a play"
    assert_raises(Spotify::Mapping::Malformed) { Spotify::Mapping.event(spotify_item(T).merge("played_at" => "")) }
    assert_raises(Spotify::Mapping::Malformed) { Spotify::Mapping.event(spotify_item(T).tap { |i| i["track"]["type"] = "episode" }) }
    assert_raises(Spotify::Mapping::Malformed) { Spotify::Mapping.event(spotify_item(T).merge("played_at" => "yesterday")) }
  end
end
