require "test_helper"

# Spotify ingestion controls and status (docs/spotify-plan.md §7, §10): Sync now, pause, resume,
# what Settings sees, and the recurring tick. Spotify is stubbed.
class SpotifyIngestionControlsTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @flag = Rails.configuration.x.spotify_ingestion_enabled
    @history_flag = Rails.configuration.x.history_import_enabled
    sign_in_via_lastfm(username: "listener")
    @user = User.sole
    @source = ListeningSource.create!(user: @user, provider: "spotify", external_account_id: "spotify-user", display_name: "Listener",
                                      connected_at: 1.day.ago, credentials: { "access_token" => "a", "refresh_token" => "r", "expires_at" => 1.year.from_now.to_i })
  end

  teardown do
    Rails.configuration.x.spotify_ingestion_enabled = @flag
    Rails.configuration.x.history_import_enabled = @history_flag
  end

  test "Sync now needs ingestion switched on, queues one poll, and refuses repeats within a minute" do
    post "/api/listening-sources/spotify/sync", headers: same_origin_headers
    assert_response :conflict
    assert_equal "ingestion_disabled", response.parsed_body["error"]

    Rails.configuration.x.spotify_ingestion_enabled = "true"
    assert_enqueued_with(job: SpotifyPollSourceJob, args: [ @source.id, { trigger: "manual", force: true } ]) do
      post "/api/listening-sources/spotify/sync", headers: same_origin_headers
    end
    assert_response :accepted

    ListeningPoll.create!(listening_source: @source, user_id: @user.id, trigger: "manual", started_at: Time.current)
    post "/api/listening-sources/spotify/sync", headers: same_origin_headers
    assert_response :too_many_requests
    assert_equal "too_soon", response.parsed_body["error"]
  end

  test "pause and resume; a paused source isn't synced" do
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    post "/api/listening-sources/spotify/pause", headers: same_origin_headers
    assert_equal true, response.parsed_body.dig("spotify", "paused")
    post "/api/listening-sources/spotify/sync", headers: same_origin_headers
    assert_equal "paused", response.parsed_body["error"]
    assert_no_enqueued_jobs(only: SpotifyPollSourceJob) { SpotifyPollJob.perform_now }

    post "/api/listening-sources/spotify/resume", headers: same_origin_headers
    assert_equal false, response.parsed_body.dig("spotify", "paused")
    assert_enqueued_with(job: SpotifyPollSourceJob, args: [ @source.id ]) { SpotifyPollJob.perform_now }
  end

  test "the recurring tick does nothing while ingestion is off" do
    assert_no_enqueued_jobs { SpotifyPollJob.perform_now }
  end

  test "status shows the last poll, new plays, errors and possible gaps, never credentials" do
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    now = Time.utc(2026, 11, 2, 12)
    stub_request(:get, %r{api\.spotify\.com/v1/me/player/recently-played}).to_return(
      status: 200, headers: { "Content-Type" => "application/json" },
      body: { items: [ spotify_item(now - 60, track: "New"), spotify_item(now - 300, track: "Older") ] }.to_json
    )
    travel_to(now) { perform_enqueued_jobs { SpotifyPollSourceJob.perform_later(@source.id) } }
    @source.reload.update!(high_water_at: now - 600) # pretend an earlier poll had recorded up to here
    ListeningGap.create!(listening_source: @source, user_id: @user.id, gap_from: now - 3.days, gap_to: now - 2.days, detected_at: now)

    get "/api/listening-sources"
    s = response.parsed_body["spotify"]
    assert_equal [ true, false, 2, now.iso8601, now.iso8601, now.iso8601 ],
                 s.values_at("ingestionEnabled", "paused", "playsAdded", "lastPollAt", "lastSuccessAt", "lastNewPlayAt")
    assert_equal [ { "from" => (now - 3.days).iso8601, "to" => (now - 2.days).iso8601, "detectedAt" => now.iso8601 } ], s["gaps"]
    assert_equal [ "schedule", "ok", 2, 2 ], s["recentPolls"].first.values_at("trigger", "outcome", "items", "added")
    assert_equal 0, s["pendingReview"]
    assert_not_includes response.body, "\"a\""
    assert_not_includes response.body, "refresh_token"
  end

  test "plays held for review are listed with their candidates and decided by the owner only" do
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    t = Time.utc(2026, 11, 2, 12)
    Rails.configuration.x.history_import_enabled = "true"
    a = Scrobble.create!(user: @user, played_at: t, seq: 0, name_variant: NameVariant.for!(artist_name: "Band", track_name: "Song", album_name: "A"))
    Scrobble.create!(user: @user, played_at: t + 20, seq: 0, name_variant: NameVariant.for!(artist_name: "Band", track_name: "Song", album_name: "A"))
    event = Spotify::Mapping.event(spotify_item(t + 200, track: "Song", artist: "Band", album: "A"))
    held = Listening::Recorder.new(@source).record!(event).observation

    get "/api/listening-sources/reviews"
    item = response.parsed_body["items"].sole
    assert_equal [ held.id, "several_same_plays", { "artist" => "Band", "track" => "Song", "album" => "A" } ], item.values_at("id", "reason", "play")
    assert_equal [ [ a.id, "lastfm", "same" ], [ a.id + 1, "lastfm", "same" ] ], item["candidates"].map { |c| c.values_at("scrobbleId", "source", "identity") }

    post "/api/listening-sources/reviews/#{held.id}/link", params: { scrobble_id: 999_999 }.to_json,
                                                          headers: same_origin_headers.merge("Content-Type" => "application/json")
    assert_response :unprocessable_entity
    post "/api/listening-sources/reviews/#{held.id}/link", params: { scrobble_id: a.id }.to_json,
                                                          headers: same_origin_headers.merge("Content-Type" => "application/json")
    assert_equal [ "linked", [] ], response.parsed_body.values_at("result", "items")
    assert_equal [ a.id, "person" ], held.reload.values_at(:scrobble_id, :linked_by)

    reset!
    allow_lastfm_accounts("listener", "other")
    sign_in_via_lastfm(username: "other")
    post "/api/listening-sources/reviews/#{held.id}/separate", headers: same_origin_headers
    assert_response :not_found
  end
end
