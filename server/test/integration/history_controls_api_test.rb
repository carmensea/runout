require "test_helper"

# Stage 2.8 endpoints (docs/milestone-2-plan.md §15.1, §15.2): import and sync controls, the
# review queue and decisions. Signed-in user only, same-origin writes,
# nothing that changes history while storage is off. Synthetic data only.
class HistoryControlsApiTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper
  include HistoryHelpers

  setup do
    sign_in_via_lastfm(username: "listener")
    @user = User.sole
  end

  def post_json(path, params = {}) = post(path, params: params, headers: same_origin_headers, as: :json)
  def body = response.parsed_body

  # HistoryHelpers switches storage on for these tests (synthetic data only).

  # The import finished: what sync and review need.
  def imported!
    @user.lastfm_connection.update!(history_state: "imported")
    ImportRun.create!(user: @user, kind: "full", state: "completed", started_at: 1.hour.ago, finished_at: 1.hour.ago)
  end

  def month(from = Time.utc(2014, 3, 1), state: "committed", **attrs)
    window(@user, from: from, to: from.next_month, state: state, validated_at: Time.current,
                  committed_at: (Time.current if state == "committed"), committed_count: (2 if state == "committed"), **attrs)
  end

  def pending_removal
    w = month
    s = scrobble(@user, at: Time.utc(2014, 3, 15, 20), variant: variant(track: "Gone"))
    f = fetch(w, outcome: "validated")
    ScrobbleRemoval.create!(user: @user, scrobble: s, first_missing_fetch: f, confirming_fetch: f, state: "pending_review")
  end

  def open_dispute
    w = month(Time.utc(2014, 4, 1))
    s = scrobble(@user, at: Time.utc(2014, 4, 2, 9), variant: variant(track: "Old name"))
    f = fetch(w, outcome: "validated")
    ReconciliationDispute.create!(user: @user, import_window: w, played_at: s.played_at, stored_scrobble_ids: [ s.id ],
                                  proposed_variant_ids: [ variant(track: "New name").id ], evidence_key: "k", first_seen_fetch: f,
                                  last_seen_fetch: f)
  end

  test "writes need the app's origin; everything needs a signed-in user" do
    post "/api/sync/pause", as: :json
    assert_response :forbidden
    delete "/api/session", headers: same_origin_headers
    %w[/api/import /api/sync /api/reviews].each do |path|
      get path
      assert_response :unauthorized, path
    end
  end

  test "with storage off, nothing that changes history runs, and status says so" do
    imported!
    Rails.configuration.x.history_import_enabled = "false" # HistoryHelpers switches it back afterwards
    [ "/api/import", "/api/import/pause", "/api/sync/refresh", "/api/sync/pause", "/api/reviews/removal/1/approve" ].each do |path|
      post_json path, confirm: true, version: "v"
      assert_response :conflict, path
      assert_equal "storage_disabled", body["error"], path
    end
    get "/api/import"
    assert_equal [ false, false ], body.values_at("enabled", "canStart")
    assert_no_enqueued_jobs
  end

  test "import controls: start once, pause, resume, cancel only with confirmation" do
    get "/api/import"
    assert_equal [ true, "not_started" ], body.values_at("canStart", "state")

    post_json "/api/import"
    assert_response :accepted
    assert_enqueued_jobs 1, only: ImportRunJob
    post_json "/api/import"
    assert_response :ok
    assert body["already"], "a second click starts nothing"
    assert_equal 1, ImportRun.count

    post_json "/api/import/pause"
    assert_equal "paused", ImportRun.sole.state
    post_json "/api/import/resume"
    assert_equal "planning", ImportRun.sole.state
    post_json "/api/import/cancel"
    assert_response :unprocessable_content
    assert_equal "confirmation_required", body["error"]
    post_json "/api/import/cancel", confirm: true
    assert_equal "cancelled", ImportRun.sole.state
    post_json "/api/import/cancel", confirm: true
    assert_response :conflict
  end

  test "retrying a stopped period: only the user's own, only when stopped" do
    imported!
    stopped = month(state: "needs_review", committed_at: nil, review_reason: "undated_rows")
    post_json "/api/import/periods/#{month(Time.utc(2014, 5, 1)).id}/retry"
    assert_response :conflict
    assert_equal "not_stopped", body["error"]

    allow_lastfm_accounts("listener", "other")
    other = User.create!(display_name: "other")
    theirs = window(other, from: Time.utc(2014, 3, 1), to: Time.utc(2014, 4, 1), state: "needs_review")
    post_json "/api/import/periods/#{theirs.id}/retry"
    assert_response :not_found
    assert_equal "needs_review", theirs.reload.state

    post_json "/api/import/periods/#{stopped.id}/retry"
    assert_response :ok
    assert_equal [ "pending", nil ], [ stopped.reload.state, stopped.review_reason ]
    assert_equal 1, ImportRun.where(kind: "sync").count, "a sync was started to pick it up"
  end

  test "sync status answers 304 while nothing changed" do
    imported!
    get "/api/sync"
    assert_response :ok
    etag = response.headers["ETag"]
    assert etag
    get "/api/sync", headers: { "If-None-Match" => etag }
    assert_response :not_modified

    travel 1.second
    post_json "/api/sync/pause"
    get "/api/sync", headers: { "If-None-Match" => etag }
    assert_response :ok
    assert body["syncPaused"]
    assert_equal "sync_paused", body["activity"]
  end

  test "refresh now: starts a sync, at most every 5 minutes; refused when sync can't run" do
    post_json "/api/sync/refresh"
    assert_response :conflict
    assert_equal "not_eligible", body["error"], "the import hasn't completed"

    imported!
    post_json "/api/sync/refresh"
    assert_response :accepted
    ImportRun.where(kind: "sync").update_all(state: "completed", finished_at: Time.current)
    post_json "/api/sync/refresh"
    assert_response :too_many_requests
    assert body["retryAfter"]
    travel 6.minutes
    post_json "/api/sync/refresh"
    assert_response :accepted
  end

  test "pause and resume sync, idempotently" do
    imported!
    post_json "/api/sync/pause"
    assert_equal [ true, false ], body.values_at("paused", "already")
    post_json "/api/sync/pause"
    assert body["already"]
    get "/api/connection"
    assert_equal [ "synced", true ], body.values_at("status", "syncPaused")
    post_json "/api/sync/resume"
    assert_equal [ true, false ], body.values_at("resumed", "already")
    assert_nil @user.lastfm_connection.reload.sync_paused_at
  end

  test "the review queue lists actionable items with their evidence; the banner counts them" do
    imported!
    removal = pending_removal
    dispute = open_dispute
    ScrobbleRemoval.create!(user: @user, scrobble: scrobble(@user, at: Time.utc(2014, 3, 20), variant: variant(track: "Once")),
                            first_missing_fetch: removal.first_missing_fetch) # seen missing once: not actionable yet
    get "/api/reviews"
    assert_equal 2, body["total"]
    assert_equal 1, body["waiting"]
    first, second = body["items"]
    assert_equal [ "removal", removal.id, "Gone" ], [ first["kind"], first["id"], first.dig("play", "track") ]
    assert_equal [ "dispute", dispute.id ], [ second["kind"], second["id"] ]
    assert_equal [ "Old name" ], second["stored"].map { |p| p["track"] }
    assert_equal [ { "artist" => "Artist", "track" => "New name", "album" => "Album", "index" => 0 } ], second["fetched"]
    assert second["version"]

    get "/api/connection"
    assert_equal 2, body["attention"]
  end

  test "a removal needs confirmation and the version seen; repeating it changes nothing; it is audited" do
    imported!
    removal = pending_removal
    get "/api/reviews"
    version = body["items"].sole["version"]

    post_json "/api/reviews/removal/#{removal.id}/approve", version: version
    assert_response :unprocessable_content
    assert_equal "confirmation_required", body["error"]
    post_json "/api/reviews/removal/#{removal.id}/approve", confirm: true
    assert_equal "version_required", body["error"]

    post_json "/api/reviews/removal/#{removal.id}/approve", confirm: true, version: version, note: "deleted on purpose"
    assert_response :ok
    assert_equal "approved", body["result"]
    assert_nil body["item"], "no longer awaiting review"
    assert removal.scrobble.reload.removed_at, "hidden, not deleted"
    post_json "/api/reviews/removal/#{removal.id}/approve", confirm: true, version: version
    assert_equal "already", body["result"], "a double submission changes nothing"

    decision = ReviewDecision.where(subject_type: "ScrobbleRemoval", subject_id: removal.id).sole
    assert_equal [ "approved", "web", @user.id, "deleted on purpose" ], [ decision.action, decision.source, decision.decided_by_id, decision.details["note"] ]
  end

  test "an item that changed while the screen was open is not decided; the current item comes back" do
    imported!
    removal = pending_removal
    get "/api/reviews"
    seen = body["items"].sole["version"]
    travel 1.second
    removal.touch # a later check updated it

    post_json "/api/reviews/removal/#{removal.id}/dismiss", version: seen
    assert_response :conflict
    assert_equal "changed", body["error"]
    assert_equal removal.id, body.dig("item", "id")
    assert_not_equal seen, body.dig("item", "version")
    assert_equal "pending_review", removal.reload.state
  end

  test "resolving a dispute applies only the reviewer's pairs, with confirmation; other users' items are invisible" do
    imported!
    dispute = open_dispute
    get "/api/reviews"
    item = body["items"].sole
    stored_id = item["stored"].sole["id"]

    post_json "/api/reviews/dispute/#{dispute.id}/resolve", version: item["version"], pairs: [ [ stored_id, 0 ] ]
    assert_response :unprocessable_content
    post_json "/api/reviews/dispute/#{dispute.id}/resolve", version: item["version"], pairs: [ [ stored_id, 5 ] ], confirm: true
    assert_response :unprocessable_content
    assert_equal "invalid", body["error"]

    post_json "/api/reviews/dispute/#{dispute.id}/resolve", version: item["version"], pairs: [ [ stored_id, 0 ] ], confirm: true
    assert_response :ok
    assert_equal "resolved", body["result"]
    assert_equal "New name", Scrobble.find(stored_id).name_variant.track_name
    assert_equal "Old name", ScrobbleCorrection.sole.from_variant.track_name, "the original name is kept"

    other = User.create!(display_name: "other")
    theirs = ScrobbleRemoval.create!(user: other, scrobble: scrobble(other, at: Time.utc(2014, 3, 1)),
                                     first_missing_fetch: fetch(window(other, from: Time.utc(2014, 3, 1), to: Time.utc(2014, 4, 1))),
                                     state: "observed")
    post_json "/api/reviews/removal/#{theirs.id}/dismiss", version: "x"
    assert_response :not_found
  end
end
