require "test_helper"

# Stage 2.7: ongoing synchronisation after the full import, through the real job chain (drained
# like a worker would) with a synthetic Last.fm and a controlled clock. Synthetic data only.
class HistoryImport::SyncTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ImportHelpers

  def sync = HistoryImport::Sync

  # Completes the full import at `at` (its cutoff), with the synthetic history plus `extra` plays.
  def import!(at:, extra: [])
    travel_to at
    @user = linked_user
    serve_history(synthetic_history + extra)
    orchestrator.start!(@user)
    drain
    assert_equal "completed", run_for(@user).state
    @cutoff = at.utc.beginning_of_minute
  end

  def windows(user = @user) = ImportWindow.live.where(user: user).order(:window_from).to_a
  def stored(track, user = @user) = Scrobble.joins(:name_variant).where(user: user, name_variants: { track_name: track })
  def last_run(kind) = ImportRun.where(user: @user, kind: kind).order(:started_at, :id).last
  def health = HistoryImport::SyncHealth.for(@user)
  def target_at(now) = (now - sync.config[:settle]).utc.beginning_of_minute

  def tick_and_drain(at: nil)
    travel_to(at) if at
    outcome = sync.tick![@user.id]
    drain
    outcome
  end

  # Coverage is one contiguous run of non-overlapping windows from the first month to `to`, and
  # every stored play lies inside a committed window.
  def assert_contiguous(to:)
    ws = windows
    ws.each_cons(2) { |a, b| assert_equal a.window_to, b.window_from, "no gap or overlap between #{a.window_to} and #{b.window_from}" }
    assert_equal to, ws.last.window_to
    assert ws.all? { |w| w.state == "committed" }, ws.map { |w| [ w.window_from, w.state, w.last_error_message ] }.inspect
    assert_equal :complete, ImportCoverage.status_for(@user, ws.first.window_from, to)
    assert_equal ws.sum(&:committed_count), Scrobble.present.where(user: @user).count, "every play in a committed window"
    assert_equal Scrobble.where(user: @user).count, Scrobble.where(user: @user).distinct.count("(played_at, seq)"), "no slot used twice"
  end

  test "the next sync picks up plays after the import's cutoff; the current month grows, nothing overlaps" do
    import!(at: Time.utc(2026, 10, 14, 12, 0, 30))
    month_count = windows.size
    assert_equal @cutoff, windows.last.window_to
    @fake.add(play(@cutoff, "At the cutoff"))           # `to` was exclusive: not fetched by the import
    @fake.add(play(@cutoff + 40.minutes, "After cutoff"))
    @fake.add(play(@cutoff + 52.minutes, "Still arriving")) # inside the settle margin at the first sync

    travel_to @cutoff + 20.minutes
    assert_equal :not_due, sync.tick![@user.id], "nothing for 30 minutes after the import"
    assert_equal "sync", tick_and_drain(at: @cutoff + 60.minutes)
    run = last_run("sync")
    assert_equal "completed", run.state, run.last_error
    assert_equal [ 2, @cutoff - 24.hours + 15.minutes, target_at(@cutoff + 60.minutes) ],
                 [ run.committed_scrobbles, run.history_from + 15.minutes, run.cutoff_at ]
    assert_equal 1, stored("At the cutoff").count
    assert_equal 1, stored("After cutoff").count
    assert_equal 0, stored("Still arriving").count, "left for the next sync"
    assert_equal month_count, windows.size, "the current month's window grew; no new window"
    assert_contiguous(to: target_at(@cutoff + 60.minutes))
    assert_nil windows.last.check_from
    assert_equal Time.current, @user.lastfm_connection.reload.last_synced_at

    assert_equal "sync", tick_and_drain(at: @cutoff + 91.minutes)
    assert_equal 1, stored("Still arriving").count
    assert_equal 1, stored("At the cutoff").count, "the lookback rechecks, it doesn't duplicate"
    assert_contiguous(to: target_at(@cutoff + 91.minutes))
    assert_equal({ disputes: 0, suspectedRemovals: 0, pendingRemovals: 0, reappeared: 0 }, health[:reviews])
  end

  test "across the year boundary: December is completed, January gets its own window; midnight belongs to January" do
    import!(at: Time.utc(2026, 12, 31, 23, 30))
    @fake.add(play(Time.utc(2026, 12, 31, 23, 59, 59), "Last second of the year"))
    @fake.add(play(Time.utc(2027, 1, 1), "Midnight"))
    @fake.add(play(Time.utc(2027, 1, 1, 0, 20), "New year"))

    assert_equal "sync", tick_and_drain(at: Time.utc(2027, 1, 1, 1, 0))
    december, january = windows.last(2)
    assert_equal [ Time.utc(2026, 12, 1), Time.utc(2027, 1, 1) ], [ december.window_from, december.window_to ]
    assert_equal [ Time.utc(2027, 1, 1), Time.utc(2027, 1, 1, 0, 45) ], [ january.window_from, january.window_to ]
    assert_equal 2, january.committed_count, "midnight is January's: `from` is inclusive, `to` exclusive"
    assert_equal 1, stored("Midnight").count
    assert_equal 1, stored("Last second of the year").count
    assert_contiguous(to: Time.utc(2027, 1, 1, 0, 45))
  end

  test "after missed syncs: a leap February is completed, an empty month is committed with 0, the current month starts" do
    import!(at: Time.utc(2028, 2, 27, 10, 0))
    @fake.add(play(Time.utc(2028, 2, 29, 12), "Leap day"))
    @fake.add(play(Time.utc(2028, 4, 2, 9), "April"))

    travel_to Time.utc(2028, 4, 3)
    run = sync.start!(@user, kind: "sync")
    drain
    assert_equal "completed", run.reload.state, run.last_error
    february, march, april = windows.last(3)
    assert_equal [ Time.utc(2028, 2, 1), Time.utc(2028, 3, 1) ], [ february.window_from, february.window_to ]
    assert_equal [ Time.utc(2028, 3, 1), Time.utc(2028, 4, 1), 0 ], [ march.window_from, march.window_to, march.committed_count ]
    assert_equal [ Time.utc(2028, 4, 1), target_at(Time.current), 1 ], [ april.window_from, april.window_to, april.committed_count ]
    assert_equal 1, stored("Leap day").count
    assert_contiguous(to: target_at(Time.current))
  end

  test "back-dated plays: the daily catch-up finds them within 14 days; the weekly count comparison finds older ones" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 9, 8), "Offline, 5 days back")) # before the cutoff, outside the lookback
    @fake.add(play(Time.utc(2026, 8, 20, 8), "Offline, 2 months back"))
    renamed = @fake.plays.index { |p| p.played_at.month == 9 }
    @fake.replace_at(renamed, track: "Renamed in September") # same count: no signal

    assert_equal "sync", tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal 0, stored("Offline, 5 days back").count, "the half-hourly sync looks back 24 hours only"

    assert_equal "catch_up", tick_and_drain(at: Time.utc(2026, 10, 15, 12, 5))
    assert_equal "completed", last_run("catch_up").state, last_run("catch_up").last_error
    assert_equal 1, stored("Offline, 5 days back").count
    assert_equal 0, stored("Offline, 2 months back").count

    august = windows.find { |w| w.window_from == Time.utc(2026, 8, 1) }
    september = windows.find { |w| w.window_from == Time.utc(2026, 9, 1) }
    verified_before = september.last_verified_at
    assert_equal "reconcile", tick_and_drain(at: Time.utc(2026, 10, 21, 12, 30))
    run = last_run("reconcile")
    assert_equal "completed", run.state, run.last_error
    assert run.count_scan, "still marked as the weekly comparison"
    assert_not_equal "reconcile", sync.due_kind(@user), "not due again for a week"
    assert_equal 1, stored("Offline, 2 months back").count, "August's count differed, so it was checked again"
    assert_equal Time.current, august.reload.last_verified_at
    assert_equal [ Time.current, september.committed_count ], [ september.reload.count_checked_at, september.remote_count ]
    assert_equal verified_before, september.last_verified_at, "equal counts never count as a verification"
    assert ReconciliationDispute.none?, "a rename keeps the count: the comparison can't see it (a discovery signal only)"
    assert windows.all? { |w| w.count_checked_at == Time.current }, "every committed month compared"
  end

  test "deleted and corrected plays found by sync go to review; nothing is removed automatically" do
    recent = Array.new(3) { |i| play(Time.utc(2026, 10, 14, 9) + (i * 600), "Recent #{i}") }
    import!(at: Time.utc(2026, 10, 14, 12), extra: recent)
    @fake.remove_if { |p| p.track == "Recent 0" }
    @fake.replace_at(@fake.plays.index { |p| p.track == "Recent 1" }, track: "Recent 1 (corrected)")

    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal "observed", ScrobbleRemoval.sole.state
    assert_equal [ "Recent 1" ], ReconciliationDispute.sole.stored_scrobbles.map { |s| s.name_variant.track_name }
    tick_and_drain(at: Time.utc(2026, 10, 14, 13, 31))
    assert_equal "pending_review", ScrobbleRemoval.sole.reload.state, "a second independent validated check"
    assert_nil stored("Recent 0").sole.removed_at
    assert_equal 1, ReconciliationDispute.count, "unchanged evidence: the same dispute"
    assert_equal({ disputes: 1, suspectedRemovals: 0, pendingRemovals: 1, reappeared: 0 }, health[:reviews])
    assert_equal :differences, HistoryImport::SyncStatus.for(@user).last.status
    assert_equal :complete, ImportCoverage.status_for(@user, windows.first.window_from, windows.last.window_to)
  end

  test "plays arriving while a sync runs: mid-read ones are re-read; late ones are caught by the next sync" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 14, 12, 20), "Before the sync"))
    requests = @fake.requests
    @fake.before_request = lambda do |n, fake|
      fake.add(play(Time.utc(2026, 10, 14, 12, 25), "Mid-read")) if n == requests + 2 # between the first and second read
    end
    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal 1, stored("Mid-read").count, "the reads disagreed, so it was read again until two agreed"
    assert windows.last.fetches.exists?(outcome: "mismatch")

    @fake.before_request = nil
    @fake.add(play(Time.utc(2026, 10, 14, 12, 30), "Scrobbled late")) # inside the range already synced
    tick_and_drain(at: Time.utc(2026, 10, 14, 13, 31))
    assert_equal 1, stored("Scrobbled late").count
    assert_contiguous(to: Time.utc(2026, 10, 14, 13, 16))
  end

  test "duplicate ticks and redelivered jobs start one run and apply it once" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))
    travel_to Time.utc(2026, 10, 14, 13)
    assert_equal "sync", sync.tick![@user.id]
    assert_equal :busy, sync.tick![@user.id], "the same tick delivered twice"
    assert_raises(HistoryImport::Sync::Busy) { sync.start!(@user, kind: "catch_up") }
    job = enqueued_jobs.find { |j| j[:job] == ImportRunJob }
    drain
    assert_equal :superseded, orchestrator.step!(*job[:args]), "a redelivered step stops at once"
    assert_equal :not_due, sync.tick![@user.id], "a run that just finished isn't due again"
    SyncScheduleJob.perform_now
    assert_equal 1, ImportRun.where(user: @user, kind: "sync").count
    assert_equal 1, stored("New").count
  end

  test "an interrupted initial import is not synchronised; once it completes, sync starts from its cutoff" do
    travel_to Time.utc(2026, 10, 14, 12)
    @user = linked_user
    serve_history
    run = orchestrator.start!(@user)
    3.times { perform_enqueued_jobs(at: Time.current) }
    orchestrator.cancel!(run)
    clear_enqueued_jobs
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "During the pause"))

    travel_to Time.utc(2026, 10, 14, 13)
    assert_equal :not_imported, sync.tick![@user.id]
    assert_raises(HistoryImport::Sync::NotEligible) { sync.start!(@user, kind: "sync") }
    assert_no_enqueued_jobs only: ImportRunJob

    orchestrator.start!(@user) # the import continues with its original cutoff
    drain
    assert_equal "completed", run_for(@user).state
    assert_equal Time.utc(2026, 10, 14, 12), windows.last.window_to, "the original cutoff, no gap"
    assert_equal 0, stored("During the pause").count

    assert_equal "sync", tick_and_drain(at: Time.utc(2026, 10, 14, 14))
    assert_equal 1, stored("During the pause").count
    assert_contiguous(to: Time.utc(2026, 10, 14, 13, 45))
  end

  test "a sync never runs beside an import or a recheck of the same account" do
    import!(at: Time.utc(2026, 10, 14, 12))
    travel_to Time.utc(2026, 10, 14, 13)
    recheck = HistoryImport::Recheck.request!(@user)
    assert_equal :busy, sync.tick![@user.id]
    assert_equal recheck, orchestrator.start!(@user), "an import request finds the active run, it doesn't start another"
    drain
    assert_equal "completed", recheck.reload.state
    assert_equal "sync", sync.tick![@user.id]
  end

  test "an outage: bounded retries, the run fails, history is untouched; later listening continues; the period is retried after rearm_after" do
    import!(at: Time.utc(2026, 10, 14, 12))
    before = Scrobble.where(user: @user).pluck(:id, :seq, :name_variant_id, :removed_at)
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "During the outage"))
    @fake.fail_when = ->(query) { { status: 502, body: "" } if query["method"] == "user.getRecentTracks" }

    travel_to Time.utc(2026, 10, 14, 13)
    sync.tick!
    requests = @fake.requests
    12.times do # the retry delays (5 min to 6 h) add up to under 9 hours
      drain
      travel 1.hour
    end
    run = last_run("sync")
    assert_equal "failed", run.state
    assert_match(/need attention/, run.last_error)
    assert_operator @fake.requests - requests, :<=, 60, "a bounded number of requests"
    assert_equal before, Scrobble.where(user: @user).pluck(:id, :seq, :name_variant_id, :removed_at), "nothing lost or changed"
    assert_equal "imported", @user.lastfm_connection.reload.history_state, "a temporary failure doesn't fail the connection"
    assert_nil @user.lastfm_connection.last_synced_at, "no successful sync"
    assert_equal :check_stopped, HistoryImport::SyncStatus.for(@user).last.status
    assert_equal :complete, ImportCoverage.status_for(@user, windows.first.window_from, Time.utc(2026, 10, 14, 12)), "coverage kept"
    assert_equal [ "check_stopped" ], health[:problemPeriods].map { |p| p[:status].to_s }
    assert_nil health[:lastSuccessfulSyncAt]

    assert_equal 0, health[:attention][:total], "retried automatically: nothing for the owner to do"
    assert health[:problemPeriods].sole[:retriesAutomatically]

    # Last.fm is back. The period that gave up waits for rearm_after, but new listening doesn't wait for it.
    @fake.fail_when = nil
    october = windows.last
    assert_equal "sync", tick_and_drain
    run = last_run("sync")
    assert_equal "completed", run.state, "it reached its target"
    assert_equal [ october.id ], health[:problemPeriods].map { |p| p[:id] }, "the stopped period is still reported"
    october.reload
    assert_equal [ "failed", Time.utc(2026, 10, 14, 12), nil ], [ october.state, october.window_to, october.check_to ],
                 "untouched, its extension detached"
    assert_equal Time.utc(2026, 10, 14, 12), windows.last.window_from, "the detached range became a new period"
    assert_equal 1, stored("During the outage").count
    assert_equal Time.current, @user.lastfm_connection.reload.last_synced_at
    assert_equal :complete, ImportCoverage.status_for(@user, windows.first.window_from, target_at(Time.current)), "October's plays still count"
    assert_empty health[:missingPeriods]

    travel 1.day
    assert_includes %w[catch_up sync], tick_and_drain
    assert_equal "committed", october.reload.state, "tried again once rearm_after passed"
    assert_contiguous(to: target_at(Time.current))
  end

  test "a period stuck with an uncommitted extension: later periods start after the extension, and it can still complete" do
    import!(at: Time.utc(2026, 10, 14, 12))
    october = windows.last
    @fake.add(play(Time.utc(2026, 10, 14, 12, 20), "In the extension"))
    @fake.add(play(Time.utc(2026, 10, 16, 9), "Two days later"))
    @fake.fail_when = ->(query) { { status: 502, body: "" } if query["from"].to_i == Time.utc(2026, 10, 13, 12).to_i }
    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    october.reload
    assert_equal [ "failed", Time.utc(2026, 10, 14, 12), Time.utc(2026, 10, 14, 12, 45) ], [ october.state, october.window_to, october.check_to ]

    @fake.fail_when = nil
    orchestrator.cancel!(last_run("sync")) # the run ends; the period stays as it was
    october.update_columns(retry_at: nil, updated_at: Time.utc(2026, 10, 14)) # gave up long enough ago to be retried
    travel_to Time.utc(2026, 10, 16, 12)
    run = sync.start!(@user, kind: "sync")
    drain
    assert_equal "completed", run.reload.state, run.last_error
    assert_equal Time.utc(2026, 10, 14, 12, 45), october.reload.window_to, "grew to its own check range"
    assert_equal Time.utc(2026, 10, 14, 12, 45), windows.last.window_from, "the next period starts where it ends"
    assert_equal 1, stored("In the extension").count
    assert_equal 1, stored("Two days later").count
    assert_contiguous(to: target_at(Time.current))
  end

  test "rate limiting is temporary: the sync waits and finishes" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))
    @fake.rate_limit_after = @fake.requests + 1 # the account check passes, then error 29
    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal "running", last_run("sync").reload.state
    @fake.rate_limit_after = nil
    10.times do
      travel 10.minutes
      drain
    end
    assert_equal "completed", last_run("sync").reload.state, last_run("sync").last_error
    assert_equal 1, stored("New").count
  end

  test "an empty answer for a range that holds plays is not treated as deletions" do
    recent = Array.new(30) { |i| play(Time.utc(2026, 10, 14) + (i * 1200), "Recent #{i}") } # inside the lookback
    import!(at: Time.utc(2026, 10, 14, 12), extra: recent)
    @fake.remove_if { |p| p.played_at >= Time.utc(2026, 10, 1) } # Last.fm answers "no plays"

    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal 33, Scrobble.present.where(user: @user, played_at: Time.utc(2026, 10, 1)..).count, "nothing removed"
    assert ScrobbleRemoval.none?
    october = windows.last
    assert_equal "needs_review", october.state
    assert_match(/not treated as deletions/, october.last_error_message)
    assert_equal "failed", last_run("sync").state
    assert_nil @user.lastfm_connection.reload.last_synced_at

    assert_equal 1, health[:attention][:total], "an integrity stop waits for a person"

    @fake.add(play(Time.utc(2026, 10, 14, 13, 5), "Listening goes on"))
    tick_and_drain(at: Time.utc(2026, 10, 14, 13, 31))
    assert_equal "completed", last_run("sync").state, "new listening isn't held back by the period under review"
    assert_equal 1, stored("Listening goes on").count
    assert_equal [ "needs_review", Time.utc(2026, 10, 14, 12) ], [ october.reload.state, october.window_to ], "still waiting for a person"
    assert ScrobbleRemoval.none?, "still nothing treated as deleted"
    assert_equal Time.utc(2026, 10, 14, 12), windows.last.window_from
    assert_equal :complete, ImportCoverage.status_for(@user, windows.first.window_from, target_at(Time.current)),
                 "October's imported plays keep their coverage; only its check stopped"
    assert_equal 1, health[:attention][:total]
  end

  test "storage off: the tick schedules nothing; turned off mid-run, nothing more is written until it's back" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))
    travel_to Time.utc(2026, 10, 14, 13)
    Rails.configuration.x.history_import_enabled = "false"
    requests = @fake.requests
    SyncScheduleJob.perform_now
    assert_raises(HistoryImport::DisabledError) { sync.tick! }
    assert_equal 0, ImportRun.where(kind: %w[sync catch_up reconcile]).count
    assert_equal requests, @fake.requests

    Rails.configuration.x.history_import_enabled = "true"
    sync.tick!
    Rails.configuration.x.history_import_enabled = "false"
    perform_enqueued_jobs(at: Time.current) # the planning step starts, finds storage off, stops
    assert_equal requests, @fake.requests
    assert_equal 0, stored("New").count
    assert_equal "planning", last_run("sync").state

    Rails.configuration.x.history_import_enabled = "true"
    travel HistoryImport::Recovery::STALL_AFTER + 1.minute
    HistoryImport::Recovery.new.run!
    drain
    assert_equal "completed", last_run("sync").state
    assert_equal 1, stored("New").count
  end

  test "accounts are synchronised separately; deleting one mid-sync leaves the other intact" do
    import!(at: Time.utc(2026, 10, 14, 12))
    alice = @user
    allow_lastfm_accounts("listener", "other")
    bob = linked_user("other")
    orchestrator.start!(bob)
    drain
    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))

    travel_to Time.utc(2026, 10, 14, 13)
    assert_equal({ alice.id => "sync", bob.id => "sync" }, sync.tick!)
    alice.destroy!
    drain
    assert_equal 0, Scrobble.where(user_id: alice.id).count
    assert_equal 0, ImportWindow.where(user_id: alice.id).count
    @user = bob
    assert_equal "completed", last_run("sync").state
    assert_equal 1, stored("New", bob).count
  end

  test "an account mismatch stops sync before anything is fetched; it stays stopped until resumed" do
    import!(at: Time.utc(2026, 10, 14, 12))
    stub_account_check(registered: Time.utc(2001, 1, 1)) # the session now acts for another account
    requests = @fake.requests
    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    assert_equal "failed", last_run("sync").state
    assert_equal requests, @fake.requests, "no history fetched"
    connection = @user.lastfm_connection.reload
    assert_equal "failed", connection.history_state
    assert_match(/registration time/, connection.last_error)
    assert_equal :not_imported, sync.tick![@user.id], "nothing scheduled while stopped"
    assert_equal "failed", health[:connectionState]

    stub_account_check # relinked: the account matches again
    assert sync.resume!(@user)
    assert_equal "sync", tick_and_drain(at: Time.utc(2026, 10, 14, 14))
    assert_equal "completed", last_run("sync").state
  end

  test "revoked access stops sync and schedules nothing more" do
    import!(at: Time.utc(2026, 10, 14, 12))
    @user.lastfm_identity.update!(revoked_at: Time.current)
    travel_to Time.utc(2026, 10, 14, 13)
    assert_equal :not_linked, sync.tick![@user.id]
    assert_no_enqueued_jobs only: ImportRunJob
  end

  test "health reports import completion, last attempt and success, new plays and what awaits review" do
    travel_to Time.utc(2026, 10, 14, 12)
    @user = linked_user
    serve_history
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # planned, nothing committed yet
    assert_equal false, health[:importComplete]
    drain
    assert_equal true, health[:importComplete]
    assert_nil health[:lastAttemptedSyncAt]
    assert_equal Time.utc(2026, 10, 14, 12, 30).iso8601, health[:nextDue]["sync"]

    @fake.add(play(Time.utc(2026, 10, 14, 12, 10), "New"))
    tick_and_drain(at: Time.utc(2026, 10, 14, 13))
    h = health
    assert_equal [ Time.current.iso8601, Time.current.iso8601 ], [ h[:lastAttemptedSyncAt], h[:lastSuccessfulSyncAt] ]
    assert_equal({ lastRun: 1, last24Hours: 1 }, h[:newScrobbles])
    assert_equal Time.utc(2026, 10, 14, 12, 45).iso8601, h[:syncedThrough]
    assert_equal "sync", h[:lastRun][:kind]
    assert_empty h[:problemPeriods]
    assert_equal 0, h[:awaitingRecheck]
  end

  test "a month whose count differs awaits a recheck until it is verified" do
    import!(at: Time.utc(2026, 10, 14, 12))
    september = windows.find { |w| w.window_from == Time.utc(2026, 9, 1) }
    travel 1.day
    september.update_columns(count_checked_at: Time.current, remote_count: september.committed_count + 1)
    assert_equal 1, health[:awaitingRecheck]
    assert_equal :synchronized, HistoryImport::SyncStatus.for(@user).find { |m| m.id == september.id }.status, "verified within 30 days"
    travel 31.days
    assert_equal :stale, HistoryImport::SyncStatus.for(@user).find { |m| m.id == september.id }.status, "a differing count is no match"
  end

  test "the recurring tick is configured for Solid Queue's scheduler" do
    config = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml"))
    task = config.dig("production", "history_sync")
    assert_equal "SyncScheduleJob", task["class"]
    require "fugit"
    assert_not_nil ::Fugit.parse(task["schedule"]), "Solid Queue parses schedules with Fugit"
    assert_equal SyncScheduleJob, task["class"].constantize
    assert_equal :discard, SyncScheduleJob.concurrency_on_conflict
  end
end
