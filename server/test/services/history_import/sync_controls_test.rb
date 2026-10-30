require "test_helper"

# Stage 2.8: stopped periods never hold new listening back (docs/milestone-2-plan.md §15.6), pause
# sync, background counts, and the attention count. Synthetic data only.
class HistoryImport::SyncControlsTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ImportHelpers

  def sync = HistoryImport::Sync
  def windows = ImportWindow.live.where(user: @user).order(:window_from).to_a
  def stored(track) = Scrobble.joins(:name_variant).where(user: @user, name_variants: { track_name: track })
  def health = HistoryImport::SyncHealth.for(@user)
  def target_at(now) = (now - sync.config[:settle]).utc.beginning_of_minute
  def last_run = ImportRun.where(user: @user).where.not(kind: "full").order(:started_at, :id).last

  def import!(at:)
    travel_to at
    @user = linked_user
    serve_history
    orchestrator.start!(@user)
    drain
    assert_equal "completed", run_for(@user).state
  end

  # Last.fm answers with a row it can't date for any range that holds `second`.
  def undated_at(second)
    page = { status: 200, body: { recenttracks: { "@attr" => { page: "1", perPage: "200", totalPages: "1", total: "1" },
                                                  track: [ { artist: { "#text" => "A" }, name: "No date" } ] } }.to_json }
    @fake.fail_when = ->(query) { page if query["from"] && (query["from"].to_i...query["to"].to_i).cover?(second.to_i) }
  end

  # Attention as the banner counts it agrees with the health summary.
  def assert_attention(expected)
    assert_equal expected, HistoryImport::Attention.for(@user)[:total], "Attention"
    assert_equal expected, health[:attention][:total], "SyncHealth"
  end

  test "a new month with a row Last.fm can't date: the problem is isolated to a small gap, and the rest is imported" do
    import!(at: Time.utc(2026, 10, 14, 12))
    bad = Time.utc(2026, 11, 5, 10, 30)
    undated_at(bad)
    @fake.add(play(Time.utc(2026, 11, 10, 9), "November"))
    @fake.add(play(Time.utc(2026, 11, 5, 8), "Same day, before"))

    travel_to Time.utc(2026, 11, 20, 12)
    run = sync.start!(@user, kind: "sync")
    drain
    assert_equal "completed", run.reload.state, "the sync reached its target"
    assert_equal 1, stored("November").count
    assert_equal 1, stored("Same day, before").count

    gap = health[:missingPeriods].sole
    gap_range = Time.zone.parse(gap[:from])...Time.zone.parse(gap[:to])
    assert gap_range.cover?(bad)
    assert_operator gap_range.end - gap_range.begin, :<, 2.hours, "isolated down to the minimum window size"
    assert_equal [ "needs_review", "undated_rows" ], gap.values_at(:state, :reason)
    stuck = windows.reject(&:committed_at).sole
    assert_equal [ "needs_review", "undated_rows" ], [ stuck.state, stuck.review_reason ]
    assert_equal :partial, ImportCoverage.status_for(@user, Time.utc(2026, 11, 1), target_at(Time.current)), "never claimed complete"
    assert_equal :complete, ImportCoverage.status_for(@user, Time.utc(2026, 11, 6), target_at(Time.current))
    assert_attention 1
    assert_equal Time.zone.parse(gap[:from]).iso8601, health[:coveredThrough], "contiguous coverage ends where the gap starts"

    @fake.add(play(Time.utc(2026, 11, 20, 12, 10), "Next listening"))
    travel 1.hour
    3.times do # whatever is due runs first (a month passed: the weekly comparison, then the catch-up)
      sync.tick!
      drain
    end
    assert_equal 1, stored("Next listening").count, "new listening isn't held back by the gap"
    assert_equal stuck.id, windows.reject(&:committed_at).sole.id, "the gap waits for a person; it isn't retried automatically"
  end

  test "a transient stop (snapshots kept changing) is retried automatically, once per rearm_after, and never counted as attention" do
    import!(at: Time.utc(2026, 10, 14, 12))
    flicker = play(Time.utc(2026, 10, 14, 11, 20), "Flickering")
    @fake.before_request = ->(n, fake) { n.odd? ? fake.add(flicker) : fake.remove_if { |p| p.track == "Flickering" } }
    travel_to Time.utc(2026, 10, 14, 13)
    sync.tick!
    drain
    october = ImportWindow.find(windows.find { |w| w.window_from == Time.utc(2026, 10, 1) }.id)
    assert_equal [ "needs_review", "unstable" ], [ october.state, october.review_reason ]
    assert_attention 0
    assert health[:problemPeriods].sole[:retriesAutomatically]

    @fake.before_request = nil
    @fake.remove_if { |p| p.track == "Flickering" }
    @fake.add(play(Time.utc(2026, 10, 14, 13, 10), "Meanwhile"))
    travel 30.minutes
    sync.tick!
    drain
    assert_equal "needs_review", october.reload.state, "not yet: rearm_after hasn't passed"
    assert_equal 1, stored("Meanwhile").count, "later listening carried on"

    travel 1.day
    sync.tick!
    drain
    assert_equal "committed", october.reload.state
    assert_nil october.review_reason
    assert_attention 0
  end

  test "pause sync: nothing new starts, a running sync pauses, nothing is cancelled; resuming carries on" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))
    travel_to Time.utc(2026, 10, 14, 13)
    sync.tick!
    run = last_run
    assert sync.pause!(@user)
    assert_not sync.pause!(@user), "already paused"
    assert_equal "paused", run.reload.state
    requests = @fake.requests
    drain
    assert_equal requests, @fake.requests, "the paused run's queued step does nothing"
    travel 1.hour
    assert_equal :paused, sync.tick![@user.id]
    assert_equal "sync_paused", health[:activity]
    assert health[:syncPaused]
    assert_equal 0, stored("New").count

    assert sync.unpause!(@user)
    drain
    assert_equal "completed", run.reload.state, run.last_error
    assert_equal 1, stored("New").count
    assert_equal 1, ImportRun.where(user: @user, kind: "sync").count, "the same run carried on"
  end

  test "the background count check records discrepancies once, and a check of the month clears them" do
    import!(at: Time.utc(2026, 10, 14, 12))
    result = HistoryImport::CountCheck.run!(@user.id)
    assert_equal 0, result[:mismatched]
    assert windows.all? { |w| w.present_count == w.committed_count }

    september = windows.find { |w| w.window_from == Time.utc(2026, 9, 1) }
    Scrobble.where(user: @user, played_at: september.window_from...september.window_to).first.delete # drift
    stamps = windows.to_h { |w| [ w.id, w.updated_at ] }
    travel 1.minute
    assert_equal 1, HistoryImport::CountCheck.run!(@user.id)[:mismatched]
    assert_equal [ september.id ], windows.select { |w| w.updated_at != stamps[w.id] }.map(&:id), "only the changed period is touched"
    first_seen = september.reload.count_mismatch_at
    assert_equal :inconsistent, HistoryImport::SyncStatus.for(@user).find { |m| m.id == september.id }.status
    assert_attention 1
    travel 1.day
    HistoryImport::CountCheck.run!(@user.id)
    assert_equal first_seen, september.reload.count_mismatch_at, "kept from when it was first seen"

    HistoryImport::Recheck.request!(@user, from: september.window_from, to: september.window_to)
    drain
    assert_nil september.reload.count_mismatch_at, "a check of the month re-establishes its count"
    assert_attention 0
  end

  test "windows never overlap and gaps are exactly the uncovered ranges, through random stops, retries and syncs" do
    import!(at: Time.utc(2026, 10, 14, 12))
    random = Random.new(Integer(ENV.fetch("STRESS_SEED", "31")))
    8.times do |round|
      bad = Time.current + random.rand(1..40).hours
      undated_at(bad) if random.rand < 0.5
      @fake.add(play(Time.current + random.rand(1..40).hours, "Round #{round}"))
      travel random.rand(2..48).hours
      if random.rand < 0.3 && (stopped = windows.find(&:stopped?))
        HistoryImport::Recovery.new.retry_window!(stopped)
      end
      sync.tick!
      drain
      @fake.fail_when = nil

      ws = windows
      ws.each_cons(2) { |a, b| assert_operator a.window_to, :<=, b.window_from, "round #{round}: no overlap" }
      covered = ImportCoverage.ranges(@user)
      outside = Scrobble.where(user: @user).pluck(:played_at).reject { |at| covered.any? { |r| r.cover?(at) } }
      assert_empty outside, "round #{round}: every stored play lies in an imported period"
      gaps = health[:missingPeriods].map { |g| Time.zone.parse(g[:from])...Time.zone.parse(g[:to]) }
      expected = [ ws.first.window_from, *covered.flat_map { |r| [ r.begin, r.end ] }, ws.map(&:window_to).max ]
                 .each_slice(2).filter_map { |a, b| (a...b) if a < b }
      assert_equal expected, gaps, "round #{round}: reported gaps are the uncovered ranges"
    end
  end
end
