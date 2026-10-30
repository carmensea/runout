require "test_helper"

# Stage 2.6: the import end to end through jobs, with recovery. Synthetic data only; every Last.fm
# call goes to the fake.
class HistoryImport::OrchestratorTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ImportHelpers

  setup do
    @user = linked_user
    serve_history
  end

  def bad_gateway = { status: 502, body: "" }

  # Fails every request for the window starting at `from`.
  def fail_period(from, response = bad_gateway)
    @fake.fail_when = ->(query) { response if query["from"].to_i == from.to_i }
  end

  def months = ImportWindow.where(user: @user).order(:window_from).to_a

  def oldest_month = Time.current.utc.beginning_of_month - 3.months

  test "a complete import commits every period newest first, with exact counts and coverage" do
    run = orchestrator.start!(@user)
    assert_enqueued_jobs 1, only: ImportRunJob
    drain

    run.reload
    assert_equal "completed", run.state
    assert_equal @fake.plays.size, committed_plays(@user)
    assert_equal 4, months.size
    assert months.all? { |w| w.state == "committed" }
    assert_equal months.map(&:committed_count).sum, committed_plays(@user)
    assert_equal months.sort_by(&:committed_at).map(&:window_from), months.map(&:window_from).reverse, "newest first"
    assert_equal 0, months.second.committed_count, "the empty month is committed explicitly"
    assert_equal 4, Scrobble.where(user: @user).joins(:name_variant).where(name_variants: { track_name: %w[Twice Other Later] }).count

    progress = HistoryImport::Progress.for(@user)
    assert progress.complete
    assert_equal [ :complete, 100, @fake.plays.size ], [ progress.coverage, progress.percent, progress.committed_scrobbles ]
    assert_equal({ pending: 0, processing: 0, committed: 4, failed: 0, review: 0 }, progress.windows)
    assert_equal "imported", @user.lastfm_connection.reload.history_state
    assert NameVariant.where(match_version: nil).none?, "committed variants were matched to the catalogue"
    assert ImportWindowRow.none?, "no staging left behind"
  end

  test "starting twice schedules one job chain; stale or duplicate jobs do nothing" do
    run = orchestrator.start!(@user)
    assert_equal run, orchestrator.start!(@user)
    assert_enqueued_jobs 1, only: ImportRunJob
    first_token = run.reload.job_token

    drain
    assert_equal :superseded, orchestrator.step!(run.id, first_token), "a redelivered old job stops at once"
    assert_equal :superseded, orchestrator.step!(run.id, SecureRandom.uuid)
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "a restart halfway through loses the queued job, and the watchdog resumes the import" do
    orchestrator.start!(@user)
    2.times { perform_enqueued_jobs(at: Time.current) } # plan, then the newest month
    clear_enqueued_jobs # the process restarted: the next step's job is gone
    assert_equal 1, months.count { |w| w.state == "committed" }

    assert_equal 0, HistoryImport::Recovery.new.run![:restarted], "not stalled yet"
    assert_not HistoryImport::Progress.for(@user).stalled
    travel HistoryImport::Recovery::STALL_AFTER + 1.minute
    assert HistoryImport::Progress.for(@user).stalled, "a quiet run is reported as stalled"
    assert_equal 1, HistoryImport::Recovery.new.run![:restarted]
    drain
    assert_equal "completed", run_for(@user).state
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "a failing month doesn't stop the others, and succeeds when retried later" do
    newest = Time.current.utc.beginning_of_month
    failures = 0
    @fake.fail_when = ->(query) { bad_gateway if query["from"].to_i == newest.to_i && (failures += 1) <= 2 }
    orchestrator.start!(@user)
    drain

    current = months.last
    assert_equal [ "failed", 1 ], [ current.state, current.attempts ]
    assert current.retry_at > Time.current
    assert_equal 3, months.count { |w| w.state == "committed" }, "the other months went ahead"
    assert_equal "running", run_for(@user).state
    assert_not HistoryImport::Progress.for(@user).complete
    assert_operator HistoryImport::Progress.for(@user).percent, :<, 100

    drain_with_retries
    assert_equal "completed", run_for(@user).state
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "a month that keeps failing stops for review after bounded retries; a manual retry finishes it" do
    fail_period(oldest_month)
    orchestrator.start!(@user)
    drain_with_retries

    oldest = months.first
    run = run_for(@user)
    assert_equal "needs_review", run.state
    assert oldest.gave_up?
    assert_equal HistoryImport::WindowValidator::MAX_WINDOW_ATTEMPTS, oldest.attempts
    assert_equal 3, months.count { |w| w.state == "committed" }
    progress = HistoryImport::Progress.for(@user)
    assert_equal [ false, :partial, 1 ], [ progress.complete, progress.coverage, progress.windows[:failed] ]
    requests = @fake.requests
    travel 1.day
    HistoryImport::Recovery.new.run!
    drain
    assert_equal requests, @fake.requests, "nothing retries a stopped month automatically"

    @fake.fail_when = nil
    assert HistoryImport::Recovery.new.retry_window!(oldest)
    drain
    assert_equal "completed", run.reload.state
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "a permanent Last.fm error stops the month at once instead of retrying" do
    fail_period(oldest_month, { status: 200, body: { error: 6, message: "Invalid parameters" }.to_json })
    orchestrator.start!(@user)
    drain
    assert months.first.gave_up?
    assert_equal 1, months.first.attempts
    assert_equal "needs_review", run_for(@user).state
  end

  test "a worker that crashes after validation: the watchdog resumes and commits once" do
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException -- stands in for a killed process
    HistoryImport::WindowCommitter.prepend(Module.new do
      define_method(:call) { Thread.current[:crash_commit] ? raise(crash) : super() }
    end)
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    Thread.current[:crash_commit] = true
    assert_raises(crash) { perform_enqueued_jobs(at: Time.current) }
    Thread.current[:crash_commit] = false
    assert_equal "validated", months.last.state
    assert_equal 0, committed_plays(@user)

    travel HistoryImport::Recovery::STALL_AFTER + 1.minute
    HistoryImport::Recovery.new.run!
    drain
    assert_equal @fake.plays.size, committed_plays(@user)
    assert_equal "completed", run_for(@user).state
  ensure
    Thread.current[:crash_commit] = nil
  end

  test "a worker that crashes mid-commit: nothing partial, the lease is recovered, then committed once" do
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException -- stands in for a killed process
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    Scrobble.define_singleton_method(:insert_all!) { |*| raise crash }
    assert_raises(crash) { perform_enqueued_jobs(at: Time.current) }
    Scrobble.singleton_class.remove_method(:insert_all!)
    stuck = months.last
    assert_equal "committing", stuck.state
    assert_equal 0, committed_plays(@user)

    travel [ ImportWindow::LEASE, HistoryImport::Recovery::STALL_AFTER ].max + 1.minute
    result = HistoryImport::Recovery.new.run!
    assert_equal 1, result[:leases]
    assert_equal 1, result[:restarted]
    drain
    assert_equal @fake.plays.size, committed_plays(@user)
  ensure
    Scrobble.singleton_class.remove_method(:insert_all!) if Scrobble.singleton_class.instance_methods(false).include?(:insert_all!)
  end

  test "a job redelivered after its step was interrupted takes the step over once it is dead, without the watchdog" do
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException -- stands in for the process stopping
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    job = enqueued_jobs.sole
    @fake.before_request = ->(n, _fake) { raise crash if n == 1 }
    assert_raises(crash) { perform_enqueued_jobs(at: Time.current) } # interrupted mid-fetch
    @fake.before_request = nil
    clear_enqueued_jobs
    run = run_for(@user)
    assert_equal job[:args].second, run.step_from_token

    # Solid Queue redelivers the released job, with its original token, straight away.
    assert_equal :deferred, orchestrator.step!(run.id, run.step_from_token), "the step might still be alive"
    assert_enqueued_jobs 1, only: ImportRunJob
    retry_at = Time.zone.at(enqueued_jobs.sole[:at])
    assert_in_delta ImportWindow::LEASE.from_now, retry_at, 5

    travel_to(retry_at + 1.second)
    drain
    assert_equal "completed", run.reload.state, "completed without the watchdog"
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "a late duplicate of a step that finished stops at once" do
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    token = enqueued_jobs.sole[:args].second
    perform_enqueued_jobs(at: Time.current) # the step runs and schedules the next one
    assert_equal :superseded, orchestrator.step!(run_for(@user).id, token)
  end

  test "validation renews its lease after every page, so a long fetch keeps it" do
    serve_history(Array.new(1_500) { |i| play(oldest_month + 7.days + (i * 60), "Long #{i}") })
    window = window(@user, from: oldest_month, to: oldest_month + 1.month)
    clock_at = Time.current
    @fake.before_request = ->(_n, _fake) { clock_at += 1.minute } # 8 pages per read: 8 minutes > LEASE
    result = HistoryImport::WindowValidator.new(window: window, client: stub_client(**Lastfm::Client::BACKGROUND_OPTIONS),
                                                username: "listener", clock: -> { clock_at }).call
    assert_equal :validated, result.status, result.detail
  end

  test "an expired snapshot is fetched and validated again before it is committed" do
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    HistoryImport::WindowCommitter.prepend(Module.new { define_method(:call) { Thread.current[:skip_commit] ? HistoryImport::WindowCommitter::Outcome.new(status: :skipped, detail: nil) : super() } })
    Thread.current[:skip_commit] = true
    perform_enqueued_jobs(at: Time.current) # validates the newest month, then "crashes" before committing
    Thread.current[:skip_commit] = false
    clear_enqueued_jobs
    assert_equal "validated", months.last.state
    requests = @fake.requests

    travel HistoryImport::StagingCleaner::STALE_AFTER + 1.day
    result = HistoryImport::Recovery.new.run!
    assert_equal 3, result[:staging][:stale], "the three staged plays of the current month"
    assert_equal "pending", months.last.state
    drain
    assert_operator @fake.requests, :>=, requests + 2, "the month was read again, twice"
    assert_equal @fake.plays.size, committed_plays(@user)
  ensure
    Thread.current[:skip_commit] = nil
  end

  test "pause stops new work, resume verifies the account and continues" do
    run = orchestrator.start!(@user)
    2.times { perform_enqueued_jobs(at: Time.current) }
    assert orchestrator.pause!(run)
    requests = @fake.requests
    drain
    travel 1.hour
    HistoryImport::Recovery.new.run!
    drain
    assert_equal requests, @fake.requests, "a paused run makes no requests"
    assert_equal "paused", run.reload.state

    orchestrator.resume!(run)
    assert_equal "planning", run.reload.state, "the account is checked again first"
    drain
    assert_equal "completed", run.reload.state
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "cancelling keeps committed history; a new run picks up the rest without recommitting" do
    run = orchestrator.start!(@user)
    2.times { perform_enqueued_jobs(at: Time.current) }
    first = months.last
    committed_at = first.committed_at
    orchestrator.cancel!(run)
    drain
    assert_equal "cancelled", run.reload.state
    assert_equal first.committed_count, committed_plays(@user), "committed history is kept"

    travel 10.minutes # the new run starts later than the first one's cutoff
    second = orchestrator.start!(@user)
    assert_not_equal run, second
    drain
    assert_equal "completed", second.reload.state
    assert_equal run.cutoff_at, second.cutoff_at, "the planned windows' cutoff is kept"
    assert HistoryImport::Progress.for(@user).complete, "no gap after the first run's cutoff"
    assert_equal @fake.plays.size, committed_plays(@user)
    assert_equal committed_at, first.reload.committed_at, "the committed month wasn't touched again"
  end

  test "deleting the account during an import stops it cleanly and leaves nothing behind" do
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current)
    user_id = @user.id
    @fake.before_request = ->(n, _fake) { User.find_by(id: user_id)&.destroy! if n == 1 } # mid-fetch
    drain
    assert_not User.exists?(user_id)
    assert_equal 0, Scrobble.where(user_id: user_id).count + ImportWindow.where(user_id: user_id).count + ImportRun.where(user_id: user_id).count
    assert_equal 0, ImportWindowRow.count
  end

  test "revoked access stops the run before anything else is fetched" do
    run = orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current)
    @user.lastfm_identity.update!(revoked_at: Time.current, credentials: nil)
    requests = @fake.requests
    drain
    assert_equal "failed", run.reload.state
    assert_match "revoked", run.last_error
    assert_equal requests, @fake.requests
    assert_equal "failed", @user.lastfm_connection.reload.history_state
  end

  test "Last.fm rejecting the session stops the whole run" do
    @fake.fail_when = ->(_query) { { status: 200, body: { error: 9, message: "Invalid session key" }.to_json } }
    run = orchestrator.start!(@user)
    drain
    assert_equal "failed", run.reload.state
    assert_match "Sign in with Last.fm again", run.last_error
    assert_equal 1, ImportWindow.where(user: @user, state: "failed").count, "stopped at the first period"
  end

  test "an account whose registration time changed is not imported" do
    stub_account_check(registered: Time.utc(2010, 1, 1))
    run = orchestrator.start!(@user)
    drain
    assert_equal "failed", run.reload.state
    assert_match "identity_changed", run.last_error
    assert_equal 0, @fake.requests
    assert_equal 0, ImportWindow.count
  end

  test "with storage off nothing can be scheduled, and queued jobs do nothing" do
    run = orchestrator.start!(@user)
    Rails.configuration.x.history_import_enabled = nil
    assert_raises(HistoryImport::DisabledError) { orchestrator.start!(history_user("other")) }
    assert_raises(HistoryImport::DisabledError) { CatalogueMatchJob.perform_later }
    perform_enqueued_jobs(at: Time.current)
    assert_equal 0, @fake.requests
    assert_equal "planning", run.reload.state
    travel 1.hour
    assert_equal 0, HistoryImport::Recovery.new.run![:restarted], "the watchdog schedules nothing while storage is off"
    assert_no_enqueued_jobs only: ImportRunJob
  end

  test "switching storage off mid-import writes nothing more; switching it on resumes" do
    orchestrator.start!(@user)
    perform_enqueued_jobs(at: Time.current) # plan
    @fake.before_request = ->(n, _fake) { Rails.configuration.x.history_import_enabled = nil if n == 1 }
    drain
    assert_equal 0, ImportWindowRow.count, "the validated snapshot wasn't staged"
    assert_equal 0, committed_plays(@user)

    @fake.before_request = nil
    Rails.configuration.x.history_import_enabled = "true"
    travel [ ImportWindow::LEASE, HistoryImport::Recovery::STALL_AFTER ].max + 1.minute
    HistoryImport::Recovery.new.run!
    drain
    assert_equal @fake.plays.size, committed_plays(@user)
  end

  test "progress counts only committed data, and a rising playcount never fakes completion" do
    serve_history(synthetic_history, playcount: synthetic_history.size + 500) # plays after the cutoff count on Last.fm
    run = orchestrator.start!(@user)
    2.times { perform_enqueued_jobs(at: Time.current) }
    progress = HistoryImport::Progress.for(@user)
    assert_not progress.complete
    assert_equal months.last.committed_count, progress.committed_scrobbles
    assert_equal months.last.window_from, progress.current_period.begin
    assert_equal({ pending: 3, processing: 0, committed: 1, failed: 0, review: 0 }, progress.windows)

    drain
    progress = HistoryImport::Progress.for(@user)
    assert progress.complete, "complete by coverage up to the cutoff"
    assert_equal 100, progress.percent
    assert_operator progress.committed_scrobbles, :<, progress.reported_playcount
    assert_equal run.reload.cutoff_at, progress.cutoff_at
  end

  test "the watchdog gives up on a run that keeps stalling" do
    run = orchestrator.start!(@user)
    clear_enqueued_jobs # every restart is lost too
    (HistoryImport::Recovery::MAX_STALL_KICKS + 1).times do
      travel HistoryImport::Recovery::STALL_AFTER + 1.minute
      HistoryImport::Recovery.new.run!
      clear_enqueued_jobs
    end
    assert_equal "failed", run.reload.state
    assert_match "stalled", run.last_error
  end

  test "the watchdog schedules matching for variants left unmatched, and only then" do
    variant(track: "Unmatched")
    assert HistoryImport::Recovery.new.run![:matching]
    assert_enqueued_jobs 1, only: CatalogueMatchJob
    perform_enqueued_jobs(only: CatalogueMatchJob)
    clear_enqueued_jobs
    assert_not HistoryImport::Recovery.new.run![:matching]
    assert_no_enqueued_jobs only: CatalogueMatchJob
  end

  test "jobs declare their concurrency limits" do
    assert_equal [ 1, :block ], [ ImportRunJob.concurrency_limit, ImportRunJob.concurrency_on_conflict ]
    # Discarding would drop matches requested while one runs (see CatalogueMatchJob).
    assert_equal :block, CatalogueMatchJob.concurrency_on_conflict
    assert_equal :discard, ImportWatchdogJob.concurrency_on_conflict
    assert_equal "lastfm", ImportRunJob.queue_name
  end
end

# Real concurrency: threads with their own database connections, like separate worker processes.
# Committed data, so no transactional wrapper; the test removes what it created.
class HistoryImport::OrchestratorConcurrencyTest < ActiveSupport::TestCase
  include ImportHelpers

  self.use_transactional_tests = false

  setup do
    @flag = Rails.configuration.x.history_import_enabled
    Rails.configuration.x.history_import_enabled = "true"
    @variants_before = NameVariant.maximum(:id).to_i
    tag = SecureRandom.hex(3)
    @names = [ "alice#{tag}", "bob#{tag}" ]
    allow_lastfm_accounts(*@names)
    @users = @names.map { |name| linked_user(name) }
    serve_history
  end

  teardown do
    @users.each { |u| User.find_by(id: u.id)&.destroy! }
    NameVariant.where("id > ?", @variants_before).delete_all
    Rails.configuration.x.history_import_enabled = @flag
  end

  def in_threads(count)
    start = Queue.new
    results = Queue.new
    threads = Array.new(count) do |i|
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection { results << yield(i) }
      end
    end
    count.times { start << :go }
    threads.each(&:join)
    Array.new(count) { results.pop }
  end

  test "of several simultaneous deliveries of one step, exactly one proceeds; the others wait" do
    run = orchestrator.start!(@users.first)
    orchestrator.step!(run.id, run.reload.job_token) # plan
    token = run.reload.job_token
    outcomes = in_threads(4) { orchestrator.step!(run.id, token) }
    assert_equal 3, outcomes.count(:deferred), outcomes.inspect
    assert_equal 1, (outcomes - [ :deferred ]).size, "only one did any work"
    assert_equal 1, ImportWindow.where(user: @users.first, state: "committed").count
  end

  test "two accounts import at the same time, each completely and only its own history" do
    runs = @users.map { |u| orchestrator.start!(u) }
    in_threads(2) do |i|
      run = runs[i]
      60.times do
        run.reload
        break unless run.working?

        orchestrator.step!(run.id, run.job_token)
      end
    end
    runs.each { |run| assert_equal "completed", run.reload.state }
    @users.each { |u| assert_equal @fake.plays.size, Scrobble.where(user: u).count }
  end
end
