require "test_helper"

# ListenBrainz history backfill (docs/listenbrainz-spotify-feasibility.md §4.4, PR D): pages back
# from what polling covered, records each page before moving the cursor, resumes after any stop
# without adding anything twice, keeps shared seconds across a page boundary, reports progress, and
# keeps accounts apart. ListenBrainz is stubbed; pages are ten listens here (1000 in production).
class Listenbrainz::BackfillTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ActiveJob::TestHelper
  include ListenbrainzStubs

  T = Time.utc(2026, 11, 6, 12, 0, 0)
  PAGE = 10

  setup do
    @flag = Rails.configuration.x.listenbrainz_ingestion_enabled
    Rails.configuration.x.listenbrainz_ingestion_enabled = "true"
    @now = T
    @dana = history_user("dana")
    @source = source_for(@dana, "dana_lb")
  end

  teardown { Rails.configuration.x.listenbrainz_ingestion_enabled = @flag }

  def source_for(user, name, covered_from: T - 30.days)
    ListeningSource.create!(user: user, provider: "listenbrainz", external_account_id: name, display_name: name, state: "connected",
                            connected_at: T - 1.day, covered_from: covered_from, high_water_at: T - 1.hour)
  end

  # `n` listens of distinct tracks, newest first, `step` seconds apart, ending `before` the covered time.
  def history(n, before: T - 30.days, step: 300, name: "Old")
    (1..n).map do |i|
      at = before.to_i - i * step
      { "listened_at" => at, "inserted_at" => at + 5, "recording_msid" => "msid-#{name}-#{i}",
        "track_metadata" => { "artist_name" => "Band", "track_name" => "#{name} #{i}", "release_name" => "Album",
                              "additional_info" => { "submission_client" => "Pano Scrobbler", "duration_ms" => 200_000 } } }
    end
  end

  def backfill
    Listenbrainz::Backfill.new(client: Listenbrainz::Client.new(pacer: SpotifyStubs::NullPacer.new), clock: -> { @now }, page: PAGE)
  end

  def run!(source = @source, **options) = backfill.run!(source, **options)

  def plays(user = @dana) = Scrobble.where(user: user)

  test "reads the whole history back from what polling covered, a page at a time, and reports progress" do
    old = history(25)
    stub_listens("dana_lb", old)
    stub_listen_count("dana_lb", 25 + 120)
    result = run!(pages: 2)
    assert_equal :partial, result.status
    # Each full page of ten leaves its oldest second to the next page: nine new listens a page.
    assert_equal [ "running", 18, 145, "backfill" ], [ @source.reload.backfill_state, @source.backfill_fetched, @source.backfill_total, result.poll.trigger ]
    assert_equal 18, plays.count
    assert_equal Time.at(old[18]["listened_at"] + 1).utc, @source.backfill_before, "one second after the second left for the next page"
    assert_equal Time.at(old[17]["listened_at"]).utc, @source.covered_from
    assert_equal({ "created" => 18 }, result.poll.recorded)

    @now = T + 10.minutes
    result = run!
    assert_equal :done, result.status
    assert_equal [ "done", 25, T + 10.minutes ], [ @source.reload.backfill_state, @source.backfill_fetched, @source.backfill_finished_at ]
    assert_equal 25, plays.count
    assert_equal Time.at(old.last["listened_at"]).utc, @source.covered_from
    assert_equal :skipped, run!.status, "nothing left to do"
    assert_equal 25, @source.plays_added
  end

  test "listens sharing a second across a page boundary are all kept, and a stop mid-way resumes without duplicates" do
    old = history(30)
    old[PAGE]["listened_at"] = old[PAGE - 1]["listened_at"] # the 10th and 11th in the same second
    old[PAGE]["inserted_at"] = old[PAGE - 1]["listened_at"] + 5
    stub_listens("dana_lb", old)
    stub_listen_count("dana_lb", 30)
    assert_equal :partial, run!(pages: 1).status
    assert_equal 9, plays.count, "the boundary second waits for the next page"
    assert_equal :done, run!(pages: 5).status
    assert_equal 30, plays.count, "both listens in the shared second were read on the next page, neither lost nor doubled"
    assert_equal 30, ListeningObservation.where(user: @dana).count
    assert_equal 30, @source.reload.backfill_fetched
    assert_equal [ 0, 1 ], ListeningObservation.where(user: @dana, reported_at: Time.at(old[PAGE]["listened_at"]).utc).joins(:scrobble).pluck("scrobbles.seq").sort
  end

  test "a page that fails leaves the cursor at the last recorded page; the retry adds nothing twice" do
    old = history(25)
    calls = 0
    stub_request(:get, %r{#{ListenbrainzStubs::API}/dana_lb/listens}).to_return do |request|
      calls += 1
      next { status: 503, body: "" } if calls == 2

      max_ts = Rack::Utils.parse_query(URI(request.uri).query)["max_ts"].to_i
      { status: 200, body: { payload: { listens: old.select { |l| l["listened_at"] < max_ts }.first(PAGE) } }.to_json, headers: { "Content-Type" => "application/json" } }
    end
    stub_listen_count("dana_lb", 25)
    result = run!(pages: 3)
    assert_equal [ :unavailable, "unavailable" ], [ result.status, result.poll.outcome ]
    assert_equal [ "running", 9 ], [ @source.reload.backfill_state, @source.backfill_fetched ]
    assert_equal 9, plays.count
    assert_match(/503/, @source.last_error)

    @now = T + 10.minutes
    assert_equal :done, run!(pages: 3).status
    assert_equal 25, plays.count
    assert_equal 25, ListeningObservation.where(user: @dana).count
  end

  test "a rate limit and a vanished account stop the run; a disconnected, paused, never-polled or finished account is skipped" do
    stub_listen_count("dana_lb", 5)
    stub_listens("dana_lb", [], status: 429, headers: { "Retry-After" => "60" })
    result = run!
    assert_equal [ :rate_limited, 60 ], [ result.status, result.poll.retry_after ]
    assert_equal "running", @source.reload.backfill_state

    stub_listens("dana_lb", [], status: 404)
    assert_equal :needs_reauth, run!.status
    assert_equal "needs_reauth", @source.reload.state
    assert_equal :skipped, run!.status

    @source.update!(state: "connected", paused_at: T)
    assert_equal :skipped, run!.status
    @source.update!(paused_at: nil, covered_from: nil, backfill_state: nil)
    assert_equal :skipped, run!.status, "polling has not covered anything yet"
    Rails.configuration.x.listenbrainz_ingestion_enabled = "false"
    @source.update!(covered_from: T - 30.days)
    assert_equal :skipped, run!.status
  end

  test "each account's history goes to its own user, and reruns after completion change nothing" do
    erin = history_user("erin")
    other = source_for(erin, "erin_lb")
    stub_listens("dana_lb", history(5, name: "Dana"))
    stub_listens("erin_lb", history(7, name: "Erin"))
    stub_listen_count("dana_lb", 5)
    stub_listen_count("erin_lb", 7)
    assert_equal :done, run!.status
    assert_equal :done, backfill.run!(other).status
    assert_equal({ @dana.id => 5, erin.id => 7 }, Scrobble.group(:user_id).count)
    assert_equal 0, Scrobble.where(user: @dana).joins(:name_variant).where("name_variants.track_name LIKE 'Erin%'").count

    @source.update!(backfill_state: nil, covered_from: T - 30.days) # read it all again
    result = run!
    assert_equal [ :done, { "seen" => 5 } ], [ result.status, result.poll.recorded ]
    assert_equal 5, plays.count
  end

  test "the tick queues a backfill run after each account's poll, only for accounts with history left" do
    erin = history_user("erin")
    source_for(erin, "erin_lb").update!(backfill_state: "done")
    source_for(history_user("fay"), "fay_lb", covered_from: nil)
    travel_to T do
      ListenbrainzPollJob.perform_now
    end
    polls = enqueued_jobs.select { |j| j["job_class"] == "ListenbrainzPollSourceJob" }
    backfills = enqueued_jobs.select { |j| j["job_class"] == "ListenbrainzBackfillJob" }
    assert_equal 3, polls.size
    assert_equal [ @source.id ], backfills.map { |j| j["arguments"].first }
    assert_equal 60, (Time.iso8601(backfills.first["scheduled_at"]) - T).to_i, "a minute after its poll"
  end
end
