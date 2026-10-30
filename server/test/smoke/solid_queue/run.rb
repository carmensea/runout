# Real Solid Queue smoke test (not part of bin/rails test). Runs synthetic imports through the
# actual job pipeline: real Solid Queue supervisors, dispatchers, workers and scheduler in separate
# processes, against the disposable `runout_smoke` database. Scenarios kill and restart workers,
# and shift timestamps in that database to stand in for elapsed time (lease expiry, stalls).
#
#   export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
#   bin/rails db:create     # once; then load db/schema.rb and db/queue_schema.rb into it
#   SMOKE_DIR=$(mktemp -d) bin/rails runner test/smoke/solid_queue/run.rb [scenario ...]
require_relative "boot"

module Smoke
  class Driver
    APP_TABLES = %w[scrobble_removals scrobble_corrections catalogue_reviews artist_aliases scrobbles import_window_rows
                    import_window_fetches import_windows import_runs name_variants tracks albums artists
                    lastfm_connections sessions identities users api_request_slots].freeze

    attr_reader :results

    def initialize
      @results = []
      @workers = []
    end

    # --- infrastructure -----------------------------------------------------------------------

    def reset!(control = {})
      stop_all(:KILL)
      conn = ActiveRecord::Base.connection
      raise "not the smoke database" unless conn.current_database == SMOKE_DATABASE

      queue_tables = conn.tables.grep(/\Asolid_queue_/)
      conn.execute("TRUNCATE #{(APP_TABLES + queue_tables).join(', ')} RESTART IDENTITY CASCADE")
      %w[requests.log crashed].each { |f| FileUtils.rm_f(File.join(DIR, f)) }
      Smoke.write_control(control)
      seed!
    end

    def seed!
      @user = User.create!(display_name: "Smoke")
      identity = Identity.create!(user: @user, provider: Identity::LASTFM, uid: USERNAME, username: USERNAME,
                                  registered_at: Smoke.registered_at, credentials: { "session_key" => "smoke-session" })
      LastfmConnection.create!(user: @user, identity: identity)
    end

    def start_workers(processes: 1, storage: true, recurring: false, shutdown_timeout: 25)
      env = { "SMOKE_DIR" => DIR, "SMOKE_WORKER_PROCESSES" => processes.to_s, "SMOKE_RECURRING" => recurring ? "1" : "0",
              "LASTFM_HISTORY_STORAGE_ENABLED" => storage ? "true" : "false", "LASTFM_MIN_REQUEST_INTERVAL" => "0.02",
              "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => shutdown_timeout.to_s }
      log = File.join(DIR, "worker-#{@workers.size}.log")
      pid = Process.spawn(env, "bin/rails", "runner", "test/smoke/solid_queue/worker.rb", out: log, err: log, pgroup: true)
      @workers << pid
      wait_for("#{processes} worker process(es) to register", 60) { SolidQueue::Process.where(kind: "Worker").count >= processes }
      pid
    end

    # TERM: graceful (Solid Queue waits shutdown_timeout, then releases unfinished jobs).
    # KILL: the whole process group dies at once, as on an OOM kill or a lost machine.
    def stop_workers(pid, signal)
      if signal == :KILL
        Process.kill(:KILL, -pid)
      else
        Process.kill(:TERM, pid)
      end
      Process.wait(pid)
      @workers.delete(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      @workers.delete(pid)
    end

    def stop_all(signal = :TERM) = @workers.dup.each { |pid| stop_workers(pid, signal) }

    def wait_for(what, timeout = 90)
      deadline = Time.now + timeout
      until yield
        raise "timed out waiting for #{what}" if Time.now > deadline

        sleep 0.2
      end
    end

    # Stands in for time passing in the smoke database: leases expire, runs look stalled, and
    # scheduled jobs become due. Real Solid Queue then does the rest.
    def time_passes!(seconds)
      interval = "interval '#{Integer(seconds)} seconds'"
      conn = ActiveRecord::Base.connection
      conn.execute("UPDATE import_windows SET lease_expires_at = lease_expires_at - #{interval}, retry_at = retry_at - #{interval}, " \
                   "validated_at = validated_at - #{interval}")
      conn.execute("UPDATE import_runs SET last_activity_at = last_activity_at - #{interval}, last_scheduled_at = last_scheduled_at - #{interval}, " \
                   "next_step_at = next_step_at - #{interval}, created_at = created_at - #{interval}")
      conn.execute("UPDATE solid_queue_scheduled_executions SET scheduled_at = scheduled_at - #{interval}")
      conn.execute("UPDATE solid_queue_jobs SET scheduled_at = scheduled_at - #{interval} WHERE finished_at IS NULL")
    end

    # --- checks -------------------------------------------------------------------------------

    def check(name, ok, detail = nil)
      @results << [ @scenario, name, ok, detail ]
      puts format("  %-4s %s%s", ok ? "ok" : "FAIL", name, detail ? " (#{detail})" : "")
    end

    def run = ImportRun.where(user: @user).order(:created_at).last&.reload
    def windows = ImportWindow.live.where(user: @user).order(:window_from).to_a

    def expected_multiset = Smoke.plays.map { |p| [ p.played_at.to_i, p.artist, p.track ] }.tally

    def stored_multiset
      Scrobble.where(user: @user).joins(:name_variant).pluck(:played_at, "name_variants.artist_name", "name_variants.track_name")
              .map { |at, artist, track| [ at.to_i, artist, track ] }.tally
    end

    # Holds at every moment: plays exist only for committed windows, exactly as many as each
    # window's committed_count, never more than Last.fm has, and never duplicated.
    def check_no_partial_or_duplicate_plays(label = "no duplicate or partial plays")
      problems = []
      windows.each do |w|
        stored = Scrobble.where(user: @user).played_between(w.window_from, w.window_to).count
        expected = w.state == "committed" ? w.committed_count : 0
        problems << "#{w.window_from.to_date} #{w.state}: #{stored} stored, #{expected} expected" unless stored == expected
      end
      extra = stored_multiset.sum { |play, n| [ n - expected_multiset.fetch(play, 0), 0 ].max }
      problems << "#{extra} plays not in the synthetic history (or duplicated)" if extra.positive?
      check(label, problems.empty?, problems.join("; ").presence)
    end

    def check_complete(label = "import completed with every play")
      r = run
      progress = HistoryImport::Progress.for(@user)
      check(label, r.state == "completed" && stored_multiset == expected_multiset,
            "run #{r.state}, #{Scrobble.where(user: @user).count} of #{Smoke.plays.size} plays")
      check("coverage complete, progress 100%", progress.complete && progress.coverage == :complete && progress.percent == 100,
            "coverage #{progress.coverage}, #{progress.percent}%, windows #{progress.windows}")
      check_no_partial_or_duplicate_plays
    end

    def wait_for_run(*states, timeout: 120)
      wait_for("run to reach #{states.join('/')}", timeout) { states.include?(run&.state) }
    end

    def dump_state
      r = run
      puts "    run: #{r&.attributes&.slice('state', 'job_token', 'last_error', 'stall_kicks', 'last_activity_at', 'next_step_at').inspect}"
      windows.each { |w| puts "    window #{w.window_from.to_date}: #{w.attributes.slice('state', 'claim_token', 'lease_expires_at', 'attempts', 'commit_attempts', 'retry_at', 'last_error_message').inspect}" }
      puts "    jobs: #{SolidQueue::Job.group(:class_name, Arel.sql('finished_at IS NULL')).count.inspect}"
      puts "    ready #{SolidQueue::ReadyExecution.count}, scheduled #{SolidQueue::ScheduledExecution.count}, claimed #{SolidQueue::ClaimedExecution.count}, blocked #{SolidQueue::BlockedExecution.count}"
      puts "    failed: #{failed_jobs.map { |k, e| "#{k}: #{e['exception_class']} #{e['message'].to_s[0, 120]}" }.inspect}"
    end

    def failed_jobs = SolidQueue::FailedExecution.joins(:job).pluck("solid_queue_jobs.class_name", :error)

    # --- scenarios ----------------------------------------------------------------------------

    def scenario(name)
      @scenario = name
      puts "\n#{name}"
      yield
    rescue StandardError => e
      check("scenario ran to the end", false, "#{e.class}: #{e.message}")
      dump_state
    ensure
      stop_all(:KILL)
    end

    def full_import
      scenario("full import through real Solid Queue") do
        reset!
        start_workers(recurring: true)
        HistoryImport::Orchestrator.new.start!(@user)
        wait_for_run("completed")
        check_complete
        check("planned 5 monthly windows, each committed once", windows.size == 5 && windows.all? { |w| w.state == "committed" },
              windows.map { |w| [ w.window_from.to_date.to_s, w.state, w.committed_count ] }.inspect)
        wait_for("catalogue matching", 30) { NameVariant.where(match_version: nil).none? }
        check("catalogue matching ran as a job", SolidQueue::Job.where(class_name: "CatalogueMatchJob").where.not(finished_at: nil).exists?)
        wait_for("the recurring watchdog", 30) { SolidQueue::Job.where(class_name: "ImportWatchdogJob").where.not(finished_at: nil).exists? }
        check("recurring watchdog was scheduled and executed", SolidQueue::RecurringExecution.where(task_key: "import_watchdog").exists?)
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
        check("staging cleaned up", ImportWindowRow.none?)
      end
    end

    def orchestrator = HistoryImport::Orchestrator.new
    def committed_windows = windows.count { |w| w.state == "committed" }
    def recent_requests = Smoke.requests.select { |r| r["method"] == "user.getRecentTracks" }

    # No new requests for `seconds`: nothing is working on the import.
    def idle?(seconds = 3)
      before = Smoke.requests.size
      sleep seconds
      Smoke.requests.size == before
    end

    # One user's steps never overlap: each window's requests form one contiguous block.
    def check_steps_serialized
      blocks = recent_requests.map { |r| r["from"] }.chunk_while { |a, b| a == b }.map(&:first)
      check("one step at a time for the user (no interleaved windows)", blocks.size == blocks.uniq.size, blocks.size.to_s)
    end

    def duplicate_delivery
      scenario("duplicate delivery and two competing worker processes") do
        reset!
        run = orchestrator.start!(@user)
        token = run.reload.job_token
        3.times { ImportRunJob.perform_later(run.id, token) } # the same job delivered again
        ImportRunJob.perform_later(run.id, SecureRandom.uuid) # a stale job
        start_workers(processes: 2)
        wait_for_run("completed")
        check_complete
        check_steps_serialized
        claimed_by = SolidQueue::Job.where(class_name: "ImportRunJob").count
        check("duplicates and the stale job ran and stopped harmlessly", claimed_by >= 5 && SolidQueue::Job.where(finished_at: nil).none?,
              "#{claimed_by} import jobs, all finished")
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
      end
    end

    def kill_during_fetch
      scenario("worker killed during a fetch, runner restarted, watchdog recovery") do
        reset!(delay: 0.15)
        pid = start_workers
        orchestrator.start!(@user)
        wait_for("a fetch in progress") { recent_requests.size >= 3 && windows.any? { |w| %w[fetching validating].include?(w.state) } }
        stop_workers(pid, :KILL)
        check_no_partial_or_duplicate_plays("nothing partial after the kill")
        Smoke.write_control({})
        start_workers(recurring: true)
        wait_for("the killed job to be reported", 60) { failed_jobs.any? { |klass, _| klass == "ImportRunJob" } }
        check("the killed job is visible as a failed job", true, failed_jobs.map { |k, e| "#{k}: #{e.to_s[/\w+Error/]}" }.uniq.join(", "))
        check("not reported stalled straight away", !HistoryImport::Progress.for(@user).stalled)
        stop_all(:TERM)
        time_passes!(HistoryImport::Recovery::STALL_AFTER + ImportWindow::LEASE + 60)
        check("the stalled import is visible in progress", HistoryImport::Progress.for(@user).stalled)
        start_workers(recurring: true)
        wait_for_run("completed")
        check_complete("import completed after watchdog recovery")
      end
    end

    def crash_around_commit
      %w[before_commit during_commit].each do |point|
        scenario("worker killed #{point.tr('_', ' ')}") do
          reset!(crash: point)
          start_workers
          orchestrator.start!(@user)
          wait_for("the crash") { Smoke.marked?("crashed") }
          sleep 1
          check_no_partial_or_duplicate_plays("nothing partial right after the crash")
          w = windows.find { |x| %w[validated committing].include?(x.state) }
          check("the crashed window is left #{point == 'before_commit' ? 'validated' : 'committing'} with no plays",
                w && Scrobble.where(user: @user).played_between(w.window_from, w.window_to).none?, w&.state)
          Smoke.write_control({})
          stop_all(:TERM)
          start_workers(recurring: true)
          time_passes!(HistoryImport::Recovery::STALL_AFTER + ImportWindow::LEASE + 60)
          wait_for_run("completed")
          check_complete("import completed after recovery, the window committed once")
        end
      end
    end

    def graceful_restart
      scenario("deploy: graceful restart with a step that outlasts the shutdown timeout") do
        File.write(Rails.root.join("log/test.log"), "")
        reset!(delay: 3)
        pid = start_workers(shutdown_timeout: 2)
        orchestrator.start!(@user)
        wait_for("a fetch in progress") { recent_requests.size >= 1 }
        old_pids = SolidQueue::Process.where(kind: "Worker").pluck(:pid)
        in_progress = recent_requests.last["from"]
        stopped_at = Time.now.to_f
        stop_workers(pid, :TERM)
        later = recent_requests.select { |r| r["at"] > stopped_at + 0.5 && old_pids.include?(r["pid"]) }
        check("the stopping worker began no new window", later.all? { |r| r["from"] == in_progress }, "#{later.size} late requests")
        interrupted = windows.find { |w| %w[fetching validating].include?(w.state) && w.lease_expires_at&.future? }
        released = File.read(Rails.root.join("log/test.log")).scan(/Release claimed job.*job_id: (\d+)/).flatten.map(&:to_i)
        released_import = SolidQueue::Job.where(id: released, class_name: "ImportRunJob").where(finished_at: nil)
        check("the step was interrupted mid-window", interrupted.present?, interrupted&.window_from&.to_date.to_s)
        check("the unfinished job was released for redelivery, not failed", failed_jobs.empty? && released_import.exists?,
              "released #{released.inspect}")
        check_no_partial_or_duplicate_plays("nothing partial after the restart")
        Smoke.write_control({})
        start_workers # no watchdog: the redelivered job alone must carry on
        wait_for("the redelivered job to wait for the interrupted step's lease", 30) do
          SolidQueue::ScheduledExecution.joins(:job).where(solid_queue_jobs: { class_name: "ImportRunJob" }).exists?
        end
        check("the redelivered job deferred instead of stopping", run.step_from_token.present?)
        time_passes!(ImportWindow::LEASE + 60) # the interrupted step's lease runs out
        wait_for_run("completed", timeout: 60)
        check_complete("import completed after the restart, without the watchdog")
      end

      scenario("deploy: graceful restart between steps") do
        reset!(delay: 0.05)
        pid = start_workers(shutdown_timeout: 25)
        orchestrator.start!(@user)
        wait_for("the first commit") { committed_windows >= 1 }
        stop_workers(pid, :TERM)
        check_no_partial_or_duplicate_plays("nothing partial after the restart")
        start_workers
        wait_for_run("completed", timeout: 60)
        check_complete("import completed after the restart, without the watchdog")
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
      end
    end

    def scheduled_retry
      scenario("a failing month is retried by a scheduled job") do
        newest = Time.now.utc.beginning_of_month
        reset!(fail_from: [ newest.to_i ])
        start_workers
        orchestrator.start!(@user)
        wait_for("the other months to commit and the run to wait") do
          committed_windows == 4 && windows.last.state == "failed" && SolidQueue::ScheduledExecution.exists?
        end
        scheduled = SolidQueue::ScheduledExecution.joins(:job).where(solid_queue_jobs: { class_name: "ImportRunJob" }).pick(:scheduled_at)
        check("the retry is a scheduled Solid Queue job at the window's retry time",
              scheduled && (scheduled - windows.last.retry_at).abs < 2, "scheduled #{scheduled}, retry_at #{windows.last.retry_at}")
        check("the run keeps waiting, not finished", run.state == "running" && !HistoryImport::Progress.for(@user).complete)
        Smoke.write_control({})
        time_passes!(6.minutes)
        wait_for_run("completed", timeout: 60)
        check_complete
      end
    end

    def pause_resume_cancel
      scenario("pause and resume") do
        reset!(delay: 0.05)
        start_workers
        r = orchestrator.start!(@user)
        wait_for("the first commit") { committed_windows >= 1 }
        orchestrator.pause!(r)
        wait_for("the step in progress to finish", 30) { idle?(1) }
        check("a paused run makes no requests", idle?(3) && run.state == "paused")
        check_no_partial_or_duplicate_plays
        orchestrator.resume!(r)
        wait_for_run("completed")
        check_complete
      end

      scenario("cancel, then start again") do
        reset!(delay: 0.05)
        start_workers
        first = orchestrator.start!(@user)
        wait_for("the first commit") { committed_windows >= 1 }
        orchestrator.cancel!(first)
        wait_for("the step in progress to finish", 30) { idle?(1) }
        kept = windows.select { |w| w.state == "committed" }.to_h { |w| [ w.id, w.committed_at ] }
        check("a cancelled run makes no requests and keeps committed history",
              idle?(3) && first.reload.state == "cancelled" && kept.any?, "#{kept.size} committed windows kept")
        check_no_partial_or_duplicate_plays
        second = orchestrator.start!(@user)
        wait_for("the new run") { second.reload.state == "completed" }
        check_complete
        check("committed windows weren't committed again", kept.all? { |id, at| ImportWindow.find(id).committed_at == at })
      end
    end

    def storage_disabled
      scenario("storage disabled while work is queued") do
        reset!
        orchestrator.start!(@user) # queued while no worker runs
        start_workers(storage: false, recurring: true)
        wait_for("the queued job to run") { SolidQueue::Job.where(class_name: "ImportRunJob").where.not(finished_at: nil).exists? }
        sleep 3
        check("nothing fetched or written while storage is off",
              Smoke.requests.empty? && ImportWindow.none? && Scrobble.none? && ImportWindowRow.none? && run.state == "planning")
        check("the watchdog scheduled nothing while storage is off",
              SolidQueue::Job.where(class_name: "ImportRunJob").count == 1)
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
        stop_all
        start_workers(recurring: true)
        time_passes!(HistoryImport::Recovery::STALL_AFTER + 60)
        wait_for_run("completed")
        check_complete("import completed once storage was enabled again")
      end

      scenario("storage disabled mid-import") do
        reset!(delay: 0.2)
        pid = start_workers(shutdown_timeout: 1)
        orchestrator.start!(@user)
        wait_for("a fetch in progress") { recent_requests.size >= 2 }
        stop_workers(pid, :TERM)
        before = [ Scrobble.count, ImportWindowRow.count, committed_windows ]
        start_workers(storage: false)
        sleep 4
        check_no_partial_or_duplicate_plays("nothing partial with storage switched off")
        after = [ Scrobble.count, ImportWindowRow.count, committed_windows ]
        check("nothing new staged or committed while storage is off", before == after, "before #{before}, after #{after}")
        stop_all
        Smoke.write_control({})
        start_workers(recurring: true)
        time_passes!(HistoryImport::Recovery::STALL_AFTER + ImportWindow::LEASE + 60)
        wait_for_run("completed")
        check_complete("import completed once storage was enabled again")
      end
    end

    def configuration
      scenario("worker configuration") do
        # The real config/queue.yml (production uses the same defaults as test).
        config = SolidQueue::Configuration.new(config_file: Rails.root.join("config/queue.yml"), skip_recurring: true)
        config.valid?
        needed = config.send(:estimated_database_pool_size)
        pool = SolidQueue::Record.connection_pool.size
        check("Solid Queue accepts config/queue.yml and its pool needs", config.warnings.empty? && pool >= needed,
              "needs #{needed} connections per worker, pool #{pool}")
        puma_threads = Integer(ENV.fetch("RAILS_MAX_THREADS", 3))
        check("the default pool (5) covers Puma's default threads (#{puma_threads}) and a worker's #{needed}",
              5 >= [ puma_threads, needed ].max)

        # The production watchdog entry from config/recurring.yml.
        recurring = YAML.safe_load(ERB.new(File.read(Rails.root.join("config/recurring.yml"))).result, aliases: true)
        task = SolidQueue::RecurringTask.from_configuration("import_watchdog", **recurring.fetch("production").fetch("import_watchdog").symbolize_keys)
        gap = task.next_time.then { |t| Fugit.parse(task.schedule).next_time(t).to_t - t.to_time }
        check("production schedules ImportWatchdogJob every 10 minutes", task.valid? && task.class_name == "ImportWatchdogJob" && gap == 600,
              "#{task.schedule}: #{gap} s apart")

        source = File.read(Rails.root.join("config/environments/production.rb"))
        check("production sets the Solid Queue shutdown timeout (default 25 s, under Render's 30 s)",
              source.include?('config.solid_queue.shutdown_timeout = ENV.fetch("SOLID_QUEUE_SHUTDOWN_TIMEOUT", 25).to_i.seconds'))
      end
    end

    def reconciliation
      scenario("recheck: reconcile committed months through real Solid Queue") do
        reset!
        start_workers(recurring: true)
        orchestrator.start!(@user)
        wait_for_run("completed")
        full = run
        old = Smoke.plays.find { |p| p.track == "Old 7" }
        later = Smoke.plays.find { |p| p.track == "After" }
        Smoke.write_control(rename: [ [ old.played_at.to_i, "Old 7", "Old 7 (live)" ] ], drop: [ [ later.played_at.to_i, "After" ] ],
                            add: [ [ (Smoke.base + 25.days).to_i, "Back-dated" ] ])
        before = Scrobble.where(user: @user).pluck(:id, :seq, :name_variant_id)

        HistoryImport::Recheck.request!(@user)
        check("coverage kept while the months are rechecked", ImportCoverage.status_for(@user, full.history_from, full.cutoff_at) == :complete)
        wait_for("the recheck") { ImportRun.where(user: @user, kind: "reconcile").pick(:state) == "completed" }
        stored = Scrobble.where(user: @user)
        check("existing plays untouched: same ids, slots and names", stored.where(id: before.map(&:first)).pluck(:id, :seq, :name_variant_id).sort == before.sort)
        check("the back-dated play was added once", stored.joins(:name_variant).where(name_variants: { track_name: "Back-dated" }).count == 1)
        check("the renamed play is a dispute, not a change",
              ReconciliationDispute.open.where(user: @user).sole.stored_scrobbles.map { |x| x.name_variant.track_name } == [ "Old 7" ])
        check("the missing play is suspected, not removed",
              ScrobbleRemoval.where(user: @user).pluck(:state) == [ "observed" ] && stored.present.count == before.size + 1)
        statuses = HistoryImport::SyncStatus.for(@user).map(&:status)
        check("sync and review status per month", statuses.include?(:differences) && statuses.include?(:suspected), statuses.inspect)

        HistoryImport::Recheck.request!(@user)
        wait_for("the second recheck") { ImportRun.where(user: @user, kind: "reconcile").order(:created_at).last.state == "completed" }
        check("a second independent check moves the removal to review", ScrobbleRemoval.where(user: @user).pluck(:state) == [ "pending_review" ])
        check("nothing duplicated by the second check",
              ReconciliationDispute.where(user: @user).count == 1 && Scrobble.where(user: @user).count == before.size + 1)
        check("committed counts match the plays present",
              windows.all? { |w| w.committed_count == Scrobble.present.where(user: @user).played_between(w.window_from, w.window_to).count })
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
      end
    end

    def slow_healthy_worker
      scenario("watchdog leaves a slow but healthy worker alone") do
        reset!(delay: 6) # a request takes 6 s: one step lasts about 12 s
        start_workers(recurring: true) # the watchdog runs every 2 seconds
        orchestrator.start!(@user)
        wait_for("a fetch in progress") { recent_requests.size >= 1 }
        # The run has looked quiet for longer than STALL_AFTER, but its worker keeps renewing its lease.
        quiet = HistoryImport::Recovery::STALL_AFTER.to_i + 60
        ActiveRecord::Base.connection.execute("UPDATE import_runs SET last_activity_at = last_activity_at - interval '#{quiet} seconds', " \
                                              "last_scheduled_at = last_scheduled_at - interval '#{quiet} seconds'")
        sleep 7 # several watchdog runs while the same fetch continues
        check("the step was still the same fetch throughout", recent_requests.size <= 2, "#{recent_requests.size} requests")
        watchdog_runs = SolidQueue::Job.where(class_name: "ImportWatchdogJob").where.not(finished_at: nil).count
        check("the watchdog ran and didn't restart the run", watchdog_runs >= 2 && run.stall_kicks.zero?,
              "#{watchdog_runs} watchdog runs, stall_kicks #{run.stall_kicks}")
        Smoke.write_control({})
        wait_for_run("completed")
        check_complete
        check_steps_serialized
      end
    end

    def all = %i[configuration full_import duplicate_delivery kill_during_fetch crash_around_commit graceful_restart scheduled_retry
                 pause_resume_cancel storage_disabled reconciliation slow_healthy_worker]
  end
end

# Stray Solid Queue processes (another run, a manual start) would take jobs from these scenarios.
stray = `ps -axo command`.lines.grep(/\Asolid-queue-/)
abort "smoke: other Solid Queue processes are running; stop them first:\n#{stray.join}" if stray.any?

# rails runner enables the query cache for the whole script; polling must see fresh rows.
ActiveRecord::Base.connection_pool.disable_query_cache!
driver = Smoke::Driver.new
names = ARGV.any? ? ARGV.map(&:to_sym) : driver.all
names.each { |name| driver.public_send(name) }
failures = driver.results.reject { |r| r[2] }
puts "\n#{driver.results.size - failures.size} of #{driver.results.size} checks passed"
exit(failures.empty? ? 0 : 1)
