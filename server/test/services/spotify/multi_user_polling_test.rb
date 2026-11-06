require "test_helper"

# Multi-user Spotify polling (docs/multi-user-plan.md §1.3, §1.4, PR 3): each connected account is
# polled on its own, spread across the tick; one account's expired permission, rate limit or
# refusal never touches another's; every play lands on the account whose source reported it; a
# Spotify account connected to one Runout user cannot be connected to another. Spotify is stubbed.
class Spotify::MultiUserPollingTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ActiveJob::TestHelper

  T = Time.utc(2026, 11, 6, 12)
  RECENT = "#{SpotifyStubs::API}/me/player/recently-played".freeze

  setup do
    @flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    @now = T
    @alice = history_user("alice")
    @bob = history_user("bob")
    @a = source_for(@alice, "spotify-a")
    @b = source_for(@bob, "spotify-b")
  end

  teardown { Rails.configuration.x.spotify_ingestion_enabled = @flag }

  def source_for(user, account, expires_at: T + 1.year)
    ListeningSource.create!(user: user, provider: "spotify", external_account_id: account, display_name: account, connected_at: T - 1.day,
                            credentials: { "access_token" => "access-#{account}", "refresh_token" => "refresh-#{account}", "expires_at" => expires_at.to_i })
  end

  def poller
    account = Spotify::Account.new(client: Spotify::Client.new(pacer: SpotifyStubs::NullPacer.new), clock: -> { @now })
    Spotify::Poller.new(account: account, clock: -> { @now })
  end

  # Spotify's answer for one account's token; the token tells the sources apart.
  def stub_recent(account, items, status: 200, headers: {})
    body = status == 200 ? { items: items, limit: 50, next: nil, cursors: nil } : { error: { status: status, message: "nope" } }
    stub_request(:get, RECENT).with(query: { "limit" => "50" }, headers: { "Authorization" => "Bearer access-#{account}" })
                              .to_return(status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers))
  end

  test "the tick queues one poll per connected account, spread across the five minutes; paused and re-auth accounts are left out" do
    source_for(history_user("carol"), "spotify-c").update!(paused_at: T)
    source_for(history_user("dave"), "spotify-d").update!(state: "needs_reauth", credentials: nil)
    travel_to T do
      SpotifyPollJob.perform_now
    end
    jobs = enqueued_jobs.select { |j| j["job_class"] == "SpotifyPollSourceJob" }
    assert_equal [ @a.id, @b.id ], jobs.map { |j| j["arguments"].first }
    waits = jobs.map { |j| j["scheduled_at"] ? Time.iso8601(j["scheduled_at"]) - T : 0 }
    assert_equal [ 0, 150 ], waits.map(&:to_i), "two accounts: now and half a tick later"
  end

  test "one account's refused refresh token stops only that account; the other keeps polling and keeps its plays" do
    @b.update!(credentials: @b.credentials.merge("expires_at" => T.to_i))
    stub_request(:post, SpotifyStubs::TOKEN_URL).with(body: hash_including("refresh_token" => "refresh-spotify-b"))
                                                .to_return(status: 400, body: { error: "invalid_grant", error_description: "revoked" }.to_json)
    stub_recent("spotify-a", [ spotify_item(T - 2.minutes, track: "Alice Song", artist: "Band") ])

    assert_equal :needs_reauth, poller.poll!(@b).status
    assert_equal :ok, poller.poll!(@a).status
    assert_equal "needs_reauth", @b.reload.state
    assert_equal "connected", @a.reload.state
    assert_equal [ @alice.id ], Scrobble.pluck(:user_id).uniq
    assert_equal 0, Scrobble.where(user: @bob).count
    assert_equal 1, HistoryImport::Attention.for(@bob)[:account], "bob is told; alice is not"
    assert_equal 0, HistoryImport::Attention.for(@alice)[:account]

    @now = T + 5.minutes
    assert_equal :skipped, poller.poll!(@b).status, "no more polls until bob connects again"
    assert_equal :ok, poller.poll!(@a).status
  end

  test "a rate limit or a 403 on one account backs that account off; the other polls on" do
    stub_recent("spotify-b", [], status: 429, headers: { "Retry-After" => "120" })
    stub_recent("spotify-a", [ spotify_item(T - 2.minutes, track: "Alice Song") ])
    assert_equal :rate_limited, poller.poll!(@b).status
    assert_equal T + 120, @b.reload.next_poll_at
    assert_equal 1, @b.consecutive_failures
    assert_equal :ok, poller.poll!(@a).status
    assert_nil @a.reload.next_poll_at

    stub_recent("spotify-b", [], status: 403)
    @now = T + 3.minutes
    assert_equal :forbidden, poller.poll!(@b, force: true).status
    assert_equal :ok, poller.poll!(@a).status
    assert_equal 1, Scrobble.where(user: @alice).count, "the same play seen again is not added twice"
  end

  test "every play belongs to the account whose source reported it, even the same track at the same second" do
    at = T - 10.minutes
    stub_recent("spotify-a", [ spotify_item(at, track: "Shared Song", artist: "Band") ])
    stub_recent("spotify-b", [ spotify_item(at, track: "Shared Song", artist: "Band") ])
    assert_equal :ok, poller.poll!(@a).status
    assert_equal :ok, poller.poll!(@b).status
    assert_equal({ @alice.id => 1, @bob.id => 1 }, Scrobble.group(:user_id).count)
    assert_equal [ "created", "created" ], ListeningObservation.order(:id).pluck(:link_state), "never linked across accounts"
    assert_equal @a.id, ListeningObservation.find_by(user_id: @alice.id).listening_source_id
    assert_equal @b.id, ListeningObservation.find_by(user_id: @bob.id).listening_source_id
    assert_equal 1, ListeningSource.find(@a.id).plays_added
    assert_equal 1, ListeningSource.find(@b.id).plays_added
  end

  test "a Spotify account connected to one Runout user cannot be connected to another" do
    stub_spotify_tokens
    stub_spotify_me(id: "spotify-a", name: "Alice's Spotify")
    account = Spotify::Account.new(client: Spotify::Client.new(pacer: SpotifyStubs::NullPacer.new), clock: -> { @now })
    before = @a.reload.attributes
    assert_raises(Spotify::Account::AccountTaken) { account.connect!(user: @bob, code: "code") }
    assert_equal before, @a.reload.attributes, "alice's source is untouched"
    assert_equal 1, ListeningSource.where(user: @bob).count, "bob's own source from setup, nothing added"
    assert_equal "spotify-b", ListeningSource.find_by(user: @bob).external_account_id
  end
end
