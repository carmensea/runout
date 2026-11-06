require "test_helper"

# ListenBrainz polling (docs/listenbrainz-spotify-feasibility.md §4.2, PR B) against the sanitised
# fixture of the tester's real listens (test/fixtures/files/listenbrainz): the first read back
# 30 days, repeats kept, repeat reads recognised, the durable cursor, outages of any length,
# failed pages, rate limits, a vanished account, and two accounts apart. ListenBrainz is stubbed.
class Listenbrainz::PollerTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ActiveJob::TestHelper

  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/files/listenbrainz/listens.json").read)
  LISTENS = (FIXTURE.is_a?(Hash) ? FIXTURE.dig("payload", "listens") : FIXTURE).freeze # newest first, 9 events
  T = Time.at(1_760_000_000 + 3600).utc # an hour after the newest fixture listen
  API = "https://api.listenbrainz.org/1/user".freeze

  setup do
    @flag = Rails.configuration.x.listenbrainz_ingestion_enabled
    Rails.configuration.x.listenbrainz_ingestion_enabled = "true"
    @now = T
    @dana = history_user("dana")
    @source = source_for(@dana, "dana_lb")
  end

  teardown { Rails.configuration.x.listenbrainz_ingestion_enabled = @flag }

  def source_for(user, name)
    ListeningSource.create!(user: user, provider: "listenbrainz", external_account_id: name, display_name: name, state: "connected", connected_at: T - 1.day)
  end

  def poller
    Listenbrainz::Poller.new(client: Listenbrainz::Client.new(pacer: SpotifyStubs::NullPacer.new), clock: -> { @now })
  end

  def poll!(source = @source, **options) = poller.poll!(source, **options)

  # Serves `all` (newest first) the way ListenBrainz does: at most `count` before `max_ts`.
  def stub_listens(name, all, count: 100, status: 200, headers: {})
    stub_request(:get, %r{#{API}/#{name}/listens}).to_return do |request|
      query = Rack::Utils.parse_query(URI(request.uri).query)
      page = all
      page = page.select { |l| l["listened_at"].to_i < query["max_ts"].to_i } if query["max_ts"]
      page = page.select { |l| l["listened_at"].to_i > query["min_ts"].to_i } if query["min_ts"]
      page = page.first([ query["count"].to_i, count ].min)
      body = status == 200 ? { payload: { count: page.size, user_id: name, listens: page } } : { error: "nope", code: status }
      { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers) }
    end
  end

  def shift(listen, seconds) = listen.merge("listened_at" => listen["listened_at"].to_i + seconds)

  test "the first poll reads back 30 days, keeps every event with its fields, and keeps genuine repeats" do
    stub_listens("dana_lb", LISTENS)
    result = poll!
    assert_equal :ok, result.status
    assert_equal 9, Scrobble.where(user: @dana).count, "nine listens, repeats included"
    assert_equal({ created: 9 }, result.poll.recorded.symbolize_keys)
    assert_equal [ true, 9 ], [ result.poll.reached_known, result.poll.items ]

    obs = ListeningObservation.where(user: @dana).order(:reported_at)
    first = obs.find_by(reported_at: Time.at(1_759_996_602).utc)
    assert_equal "listen_started_at", first.timestamp_kind
    assert_equal 179_000, first.duration_ms, "Pano sends duration_ms"
    web = obs.find_by(reported_at: Time.at(1_760_000_000).utc)
    assert_equal 230_000, web.duration_ms, "Web Scrobbler sends duration in seconds"
    assert_equal "YouTube Music", web.context["music_service_name"]
    assert_equal 1_760_000_114, web.context["inserted_at"], "inserted_at kept beside listened_at"
    assert_equal "1760000000", web.reported_at_raw
    assert_equal "cf2608ef-350c-5e4b-aae9-57090245684e", web.context["recording_msid"]
    assert_equal "abdba13a-221b-58c3-8bd5-222c8aeee122", web.context.dig("mbid_mapping", "recording_mbid"), "ListenBrainz's opinion, kept as context"
    assert_nil web.name_variant.track_mbid, "never written as the variant's MusicBrainz id"
    repeats = obs.select { |o| o.context["recording_msid"] == "cf2608ef-350c-5e4b-aae9-57090245684e" }
    assert_equal 2, repeats.size
    assert_not_equal repeats[0].source_event_id, repeats[1].source_event_id, "the msid is not the event id"
    assert_equal 2, repeats.map(&:scrobble_id).uniq.size

    assert_equal Time.at(1_760_000_000).utc, @source.reload.high_water_at
    assert_equal T - 30.days, @source.covered_from
    assert_equal 9, @source.plays_added
  end

  test "polling again changes nothing; a late submission inside the overlap is picked up" do
    stub_listens("dana_lb", LISTENS)
    poll!
    @now = T + 10.minutes
    assert_equal({ seen: 9 }, poll!.poll.recorded.symbolize_keys)
    assert_equal 9, Scrobble.where(user: @dana).count

    # Submitted after the first poll with an earlier listened_at (an offline phone): before the cursor, inside the overlap.
    late = shift(LISTENS.first, -600).merge("track_metadata" => LISTENS.first["track_metadata"].merge("track_name" => "Late Submission"))
    stub_listens("dana_lb", (LISTENS + [ late ]).sort_by { |l| -l["listened_at"].to_i })
    @now = T + 20.minutes
    assert_equal({ seen: 9, created: 1 }, poll!.poll.recorded.symbolize_keys)
    assert_equal 10, Scrobble.where(user: @dana).count
    assert_equal Time.at(1_760_000_000).utc, @source.reload.high_water_at, "a late listen never moves the cursor backwards"
  end

  test "after an outage of forty days it pages back to the cursor and records everything, once" do
    stub_listens("dana_lb", LISTENS)
    poll!
    cursor = @source.reload.high_water_at
    later = (1..250).map { |i| shift(LISTENS[i % 9], 40.days.to_i + i * 600).merge("recording_msid" => "msid-#{i}") }
    stub_listens("dana_lb", (later + LISTENS).sort_by { |l| -l["listened_at"].to_i })
    @now = T + 41.days
    result = poll!
    assert_equal :ok, result.status
    assert_operator result.poll.pages, :>=, 3, "three pages of 100 back to the cursor"
    assert_equal 250, result.poll.recorded["created"]
    assert_equal 9 + 250, Scrobble.where(user: @dana).count
    assert_operator @source.reload.high_water_at, :>, cursor + 40.days
    @now = T + 41.days + 10.minutes
    assert_equal 0, poll!.poll.recorded.fetch("created", 0), "nothing twice"
  end

  test "a page that fails leaves the cursor where it was; the retry adds nothing twice" do
    stub_listens("dana_lb", LISTENS)
    poll!
    cursor = @source.reload.high_water_at
    later = (1..150).map { |i| shift(LISTENS[i % 9], 2.days.to_i + i * 600).merge("recording_msid" => "msid-#{i}") }
    all = (later + LISTENS).sort_by { |l| -l["listened_at"].to_i }
    calls = 0
    stub_request(:get, %r{#{API}/dana_lb/listens}).to_return do |request|
      calls += 1
      next { status: 503, body: "" } if calls == 2

      query = Rack::Utils.parse_query(URI(request.uri).query)
      page = all.select { |l| query["max_ts"].nil? || l["listened_at"].to_i < query["max_ts"].to_i }.first(100)
      { status: 200, body: { payload: { listens: page } }.to_json, headers: { "Content-Type" => "application/json" } }
    end
    @now = T + 3.days
    assert_equal :unavailable, poll!.status
    assert_equal cursor, @source.reload.high_water_at, "the cursor did not move"
    assert_equal 1, @source.consecutive_failures
    assert_operator @source.next_poll_at, :>, @now
    @now = T + 3.days + 5.minutes
    assert_equal :ok, poll!(force: true).status
    assert_equal 9 + 150, Scrobble.where(user: @dana).count, "page one's listens from the failed poll were never stored twice"
    assert_operator @source.reload.high_water_at, :>, cursor
  end

  test "a rate limit waits for Retry-After, a vanished account stops polling, and the other account is untouched" do
    erin = history_user("erin")
    other = source_for(erin, "erin_lb")
    stub_listens("erin_lb", LISTENS.first(2))
    stub_listens("dana_lb", [], status: 429, headers: { "Retry-After" => "90" })
    assert_equal :rate_limited, poll!.status
    assert_equal @now + 90, @source.reload.next_poll_at
    assert_equal :ok, poller.poll!(other).status
    assert_equal({ erin.id => 2 }, Scrobble.group(:user_id).count)

    stub_listens("dana_lb", [], status: 404)
    @now = T + 5.minutes
    assert_equal :needs_reauth, poll!.status
    assert_equal "needs_reauth", @source.reload.state
    assert_equal :skipped, poll!.status
    assert_equal 1, HistoryImport::Attention.for(@dana)[:account]
    assert_equal 0, HistoryImport::Attention.for(erin)[:account]
  end

  test "same-second listens of different tracks are two plays, the same track twice in one second is one, and nothing is stored while the flag is off" do
    a = LISTENS[0]
    b = LISTENS[1].merge("listened_at" => a["listened_at"])
    stub_listens("dana_lb", [ a, b ])
    assert_equal 2, poll!.poll.recorded["created"]
    assert_equal [ 0, 1 ], Scrobble.where(user: @dana).order(:seq).pluck(:seq)

    # Documented limitation: ListenBrainz keeps one listen per user, second and recording_msid (derived
    # from the names), so an identical pair is already one listen there; were it ever served, Runout
    # would keep one play, not two.
    stub_listens("dana_lb", [ a, a.merge("recording_msid" => "another-msid") ])
    @now = T + 10.minutes
    assert_equal({ seen: 2 }, poll!.poll.recorded.symbolize_keys)
    assert_equal 2, Scrobble.where(user: @dana).count

    Rails.configuration.x.listenbrainz_ingestion_enabled = "false"
    assert_equal :skipped, poll!.status
  end

  test "the tick queues one poll per connected account spread across ten minutes, and nothing while off" do
    erin = history_user("erin")
    source_for(erin, "erin_lb")
    source_for(history_user("carol"), "carol_lb").update!(paused_at: T)
    travel_to T do
      ListenbrainzPollJob.perform_now
    end
    jobs = enqueued_jobs.select { |j| j["job_class"] == "ListenbrainzPollSourceJob" }
    assert_equal 2, jobs.size
    waits = jobs.map { |j| j["scheduled_at"] ? Time.iso8601(j["scheduled_at"]) - T : 0 }
    assert_equal [ 0, 300 ], waits.map(&:to_i)

    clear_enqueued_jobs
    Rails.configuration.x.listenbrainz_ingestion_enabled = "false"
    ListenbrainzPollJob.perform_now
    assert_equal 0, enqueued_jobs.size
  end
end
