require "test_helper"

# Spotify, stage 3 (docs/spotify-plan.md §10): polling Recently Played. Repeated polls, paging back
# after time offline, possible gaps, retries and backoff, re-authorisation, the per-source lock,
# interruption, cross-source links, coverage, and the plays reaching the analytics. Synthetic
# responses only (WebMock).
class Spotify::PollerTest < ActiveSupport::TestCase
  include HistoryHelpers

  T = Time.utc(2026, 11, 2, 12)
  RECENT = "#{SpotifyStubs::API}/me/player/recently-played".freeze

  # A second connection to the test database: its own session, so its advisory locks are its own.
  class OtherConnection < ActiveRecord::Base
    self.abstract_class = true
  end

  setup do
    @flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    @now = T
    @user = history_user
    @source = connected_source(@user)
  end

  teardown { Rails.configuration.x.spotify_ingestion_enabled = @flag }

  def connected_source(user, account: "spotify-#{user.id}")
    ListeningSource.create!(user: user, provider: "spotify", external_account_id: account, display_name: "Listener", connected_at: T - 1.day,
                            credentials: { "access_token" => "access-#{account}", "refresh_token" => "refresh-1", "expires_at" => (T + 1.year).to_i })
  end

  def poller(recorder: Listening::Recorder)
    account = Spotify::Account.new(client: Spotify::Client.new(pacer: SpotifyStubs::NullPacer.new), clock: -> { @now })
    Spotify::Poller.new(account: account, clock: -> { @now }, recorder: recorder)
  end

  def poll!(source = @source, **options) = poller(**options.slice(:recorder)).poll!(source, **options.except(:recorder))

  # `plays`: [minutes before T, track], newest first, as Spotify orders them.
  def items(*plays) = plays.map { |minutes, track| spotify_item(T - minutes.minutes, track: track) }

  # One page of Recently Played, for `before` (nil for the newest page).
  def stub_page(page_items, before: nil, cursor: nil, status: 200, headers: {})
    query = { "limit" => "50" }.merge(before ? { "before" => before.to_s } : {})
    body = status == 200 ? { items: page_items, limit: 50, next: cursor && "#{RECENT}?before=#{cursor}", cursors: cursor && { after: "1", before: cursor.to_s } } : { error: { status: status, message: "nope" } }
    stub_request(:get, RECENT).with(query: query).to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers))
  end

  def many(count, from_minutes) = Array.new(count) { |i| [ from_minutes + i * 4, "Song #{from_minutes + i * 4}" ] }

  test "the first poll records plays oldest first and starts coverage; polling the same plays again adds nothing" do
    stub_page(items([ 4, "C" ], [ 8, "B" ], [ 12, "A" ]))
    result = poll!
    assert_equal :ok, result.status
    assert_equal({ "created" => 3 }, result.poll.recorded)
    assert_equal %w[A B C], Scrobble.order(:played_at).includes(:name_variant).map { |s| s.name_variant.track_name }
    @source.reload
    assert_equal [ T - 4.minutes, T - 12.minutes, 3, T, T ], @source.values_at(:high_water_at, :covered_from, :plays_added, :last_new_play_at, :last_success_at)

    @now = T + 5.minutes
    result = poll!
    assert_equal({ "seen" => 3 }, result.poll.recorded)
    assert_equal [ 3, 3, T ], [ Scrobble.count, @source.reload.plays_added, @source.last_new_play_at ]
    assert_equal 2, ListeningPoll.where(outcome: "ok").count
    assert ListeningGap.none?
  end

  test "new plays, repeats and same-second plays arrive on later polls" do
    stub_page(items([ 10, "A" ]))
    poll!
    @now = T + 5.minutes
    repeat = spotify_item(T - 1.minute, track: "A")
    same_second = spotify_item(T - 1.minute + 0.5, track: "B")
    stub_page([ same_second, repeat ] + items([ 10, "A" ]))
    assert_equal({ "created" => 2, "seen" => 1 }, poll!.poll.recorded)
    assert_equal [ [ T - 10.minutes, 0 ], [ T - 1.minute, 0 ], [ T - 1.minute, 1 ] ], Scrobble.order(:played_at, :seq).pluck(:played_at, :seq)
  end

  test "after time offline it pages back until it meets plays it already has: caught up, no gap" do
    stub_page(items([ 600, "Old" ]))
    poll!
    @now = T + 1.day
    stub_page(items(*many(50, 0)), cursor: 111)
    stub_page(items(*many(10, 200), [ 600, "Old" ]), before: 111, cursor: 222)
    result = poll!
    assert_equal [ :ok, 2, 61, true ], [ result.status, result.poll.pages, result.poll.items, result.poll.reached_known ]
    assert_equal({ "created" => 60, "seen" => 1 }, result.poll.recorded)
    assert ListeningGap.none?
    assert_equal T, @source.reload.high_water_at
  end

  test "when Spotify can't reach back far enough, the interval becomes a possible gap; nothing is made up" do
    stub_page(items([ 900, "Old" ]))
    poll!
    @now = T + 2.days
    stub_page(items(*many(50, 0)), cursor: 111)
    stub_page([], before: 111)
    result = poll!
    assert_equal [ :ok, false ], [ result.status, result.poll.reached_known ]
    gap = ListeningGap.sole
    assert_equal [ T - 900.minutes, T - 196.minutes, result.poll.id ], gap.values_at(:gap_from, :gap_to, :listening_poll_id)
    assert_equal 51, Scrobble.count, "only plays Spotify reported"

    coverage = Analytics::Coverage.new(@user, "UTC", now: @now)
    inside = coverage.for(T - 800.minutes, T - 300.minutes)
    assert_equal "none", inside[:status], "nothing is claimed inside a gap"
    assert_equal "complete", coverage.for(T - 190.minutes, T - 10.minutes)[:status]
    assert_equal "partial", coverage.for(T - 1000.minutes, T)[:status]
  end

  test "an empty answer after plays were recorded is a possible gap up to now" do
    stub_page(items([ 30, "A" ]))
    poll!
    @now = T + 1.hour
    stub_page([])
    poll!
    assert_equal [ T - 30.minutes, T + 1.hour ], ListeningGap.sole.values_at(:gap_from, :gap_to)
  end

  test "429 waits for Retry-After, even for Sync now; outages back off and recover" do
    stub_page([], status: 429, headers: { "Retry-After" => "120" })
    result = poll!
    assert_equal :rate_limited, result.status
    assert_equal [ 120, T + 120 ], [ result.poll.retry_after, @source.reload.next_poll_at ]
    @now = T + 60
    assert_equal :waiting, poll!.status
    assert_equal :waiting, poll!(force: true).status, "Sync now never overrides Spotify's Retry-After"

    @now = T + 121
    stub_page([], status: 503)
    assert_equal :unavailable, poll!.status
    assert_equal [ 2, @now + 2.minutes ], @source.reload.values_at(:consecutive_failures, :next_poll_at)
    @now += 1.minute
    assert_equal :waiting, poll!.status
    stub_page(items([ 1, "A" ]))
    assert_equal :ok, poll!(force: true).status, "Sync now skips an outage backoff"
    assert_equal [ 0, nil, nil ], @source.reload.values_at(:consecutive_failures, :next_poll_at, :last_error)
    assert_requested(:get, RECENT, query: hash_including({}), times: 3)
  end

  test "an exhausted developer quota waits at least an hour, whatever Retry-After says, and Sync now can't override it" do
    stub_page([], status: 429, headers: { "Retry-After" => "30" })
    stub_request(:get, RECENT).with(query: { "limit" => "50" }).to_return(
      status: 429, headers: { "Retry-After" => "30", "Content-Type" => "application/json" },
      body: { error: { status: 429, message: "Quota exceeded" }, reason: "QUOTA_EXCEEDED" }.to_json
    )
    result = poll!
    assert_equal [ :quota_exceeded, 30 ], [ result.status, result.poll.retry_after ]
    assert_equal [ T + 1.hour, "Spotify's quota for this developer account is used up" ], @source.reload.values_at(:next_poll_at, :last_error)
    @now = T + 10.minutes
    assert_equal :waiting, poll!(force: true).status
    assert_requested(:get, RECENT, query: hash_including({}), times: 1)
  end

  test "a 401 even after refreshing waits an hour instead of retrying like an outage" do
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(status: 200, body: { access_token: "fresh", expires_in: 3600, scope: "user-read-recently-played" }.to_json)
    stub_page([], status: 401)
    assert_equal :unauthorized, poll!.status
    assert_equal [ "connected", T + 1.hour ], @source.reload.values_at(:state, :next_poll_at)
    assert_requested(:get, RECENT, query: hash_including({}), times: 2) # the stored token, then the refreshed one
    assert_requested(:post, SpotifyStubs::TOKEN_URL, times: 1)
  end

  test "a pause the pacer still holds after a 429 counts as Spotify's rate limit, not a failure" do
    pacer = Lastfm::RequestPacer.new(key: "spotify-test-#{SecureRandom.hex(3)}", interval: 0, max_wait: 0)
    pacer.cool_down!(90)
    account = Spotify::Account.new(client: Spotify::Client.new(pacer: pacer), clock: -> { @now })
    result = Spotify::Poller.new(account: account, clock: -> { @now }).poll!(@source)
    assert_equal :rate_limited, result.status
    assert_match(/paused after a rate limit/, result.poll.error)
    assert_operator @source.reload.next_poll_at, :>=, T + 80
    assert_not_requested :get, RECENT, query: hash_including({})
  end

  test "an expired token is refreshed; a refused refresh stops polling until Spotify is connected again" do
    @source.update!(credentials: @source.credentials.merge("expires_at" => T.to_i))
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(status: 200, body: { access_token: "fresh", expires_in: 3600, scope: "user-read-recently-played" }.to_json)
    stub_page(items([ 1, "A" ]))
    assert_equal :ok, poll!.status
    assert_requested(:get, RECENT, query: { "limit" => "50" }, headers: { "Authorization" => "Bearer fresh" })

    @source.update!(credentials: @source.credentials.merge("expires_at" => T.to_i))
    stub_request(:post, SpotifyStubs::TOKEN_URL).to_return(status: 400, body: { error: "invalid_grant", error_description: "Refresh token revoked" }.to_json)
    assert_equal :needs_reauth, poll!.status
    assert_equal "needs_reauth", @source.reload.state
    assert_equal :skipped, poll!.status
  end

  test "403 waits an hour and says why" do
    stub_page([], status: 403)
    assert_equal :forbidden, poll!.status
    assert_equal [ T + 1.hour, "Spotify answered HTTP 403: nope" ], @source.reload.values_at(:next_poll_at, :last_error)
  end

  test "nothing is fetched while ingestion is off, while paused, or while another poll holds the account" do
    Rails.configuration.x.spotify_ingestion_enabled = "false"
    assert_equal :skipped, poll!.status
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    @source.update!(paused_at: T)
    assert_equal :skipped, poll!.status
    @source.update!(paused_at: nil)

    OtherConnection.establish_connection(:test)
    other = OtherConnection.connection
    key = format(Spotify::Poller::LOCK, @source.id)
    assert other.select_value(OtherConnection.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", key ]))
    assert_equal :busy, poll!.status
    other.select_value(OtherConnection.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", key ]))
    assert_not_requested :get, RECENT, query: hash_including({})
  ensure
    OtherConnection.remove_connection
  end

  test "a crash part-way records what it can; the next poll completes it without duplicates" do
    crashing = Class.new(Listening::Recorder) do
      define_method(:create_scrobble!) do |*args|
        super(*args).tap { raise IOError, "disk full" if (@calls = @calls.to_i + 1) == 2 }
      end
    end
    stub_page(items([ 4, "C" ], [ 8, "B" ], [ 12, "A" ]))
    assert_raises(IOError) { poll!(recorder: crashing) }
    poll = ListeningPoll.sole
    assert_equal [ "failed", "IOError: disk full" ], poll.values_at(:outcome, :error)
    assert_equal [ 1, nil ], [ Scrobble.count, @source.reload.high_water_at ]

    @now += 2.minutes
    assert_equal({ "seen" => 1, "created" => 2 }, poll!(force: true).poll.recorded)
    assert_equal 3, Scrobble.count
  end

  test "plays Last.fm already has are linked, not added; plays reach the Overview and the Time Machine" do
    lastfm = scrobble(@user, at: T - 30.minutes - 200, variant: variant(artist: "Band", track: "Known", album: "Album"))
    stub_page(items([ 5, "New" ], [ 30, "Known" ]))
    assert_equal({ "linked" => 1, "created" => 1 }, poll!.poll.recorded)
    assert_equal 1, @source.reload.plays_added
    assert_equal lastfm.id, ListeningObservation.find_by!(link_state: "linked").scrobble_id

    period = Analytics::Period.parse("month:2026-11", time_zone: "UTC", today: Date.new(2026, 11, 2))
    overview = Analytics::Overview.new(user: @user, period: period).call
    assert_equal 2, overview[:stats][:scrobbles]
    days = Analytics::Calendar.new(user: @user).days(Date.new(2026, 11, 2), Date.new(2026, 11, 2))
    assert_equal 2, days[:days].sum { |d| d[:scrobbles] }
  end

  test "each user's account is polled for that user only" do
    other_user = history_user("other")
    other = connected_source(other_user)
    stub_request(:get, RECENT).with(query: { "limit" => "50" }, headers: { "Authorization" => "Bearer access-#{other.external_account_id}" })
                              .to_return(status: 200, body: { items: items([ 3, "Theirs" ]) }.to_json)
    stub_request(:get, RECENT).with(query: { "limit" => "50" }, headers: { "Authorization" => "Bearer access-#{@source.external_account_id}" })
                              .to_return(status: 200, body: { items: items([ 3, "Mine" ]) }.to_json)
    poll!(other)
    poll!
    assert_equal [ "Theirs" ], Scrobble.where(user: other_user).includes(:name_variant).map { |s| s.name_variant.track_name }
    assert_equal [ "Mine" ], Scrobble.where(user: @user).includes(:name_variant).map { |s| s.name_variant.track_name }
  end
end
