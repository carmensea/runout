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
    APP_TABLES = %w[catalogue_inferences mbid_disputes scrobble_removals scrobble_corrections catalogue_reviews artist_aliases scrobbles import_window_rows
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
                                  registered_at: Smoke.large? ? Smoke.large_registered_at : Smoke.registered_at,
                                  credentials: { "session_key" => "smoke-session" })
      LastfmConnection.create!(user: @user, identity: identity)
    end

    def start_workers(processes: 1, storage: true, recurring: false, shutdown_timeout: 25)
      env = { "SMOKE_DIR" => DIR, "SMOKE_WORKER_PROCESSES" => processes.to_s, "SMOKE_RECURRING" => recurring ? "1" : "0",
              "LASTFM_HISTORY_STORAGE_ENABLED" => storage ? "true" : "false", "LASTFM_MIN_REQUEST_INTERVAL" => "0.02",
              "SOLID_QUEUE_SHUTDOWN_TIMEOUT" => shutdown_timeout.to_s,
              # Sync fetches up to the current minute: the smoke history can't wait 15 minutes.
              "SYNC_SETTLE_MINUTES" => "0" }
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
                   "validated_at = validated_at - #{interval}, updated_at = updated_at - #{interval}")
      conn.execute("UPDATE import_runs SET last_activity_at = last_activity_at - #{interval}, last_scheduled_at = last_scheduled_at - #{interval}, " \
                   "next_step_at = next_step_at - #{interval}, created_at = created_at - #{interval}, " \
                   "started_at = started_at - #{interval}, finished_at = finished_at - #{interval}")
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

    # --- Stage 2.7: ongoing synchronisation through the recurring scheduler -------------------

    def sync_runs(kind = nil)
      scope = ImportRun.where(user: @user).where.not(kind: "full")
      (kind ? scope.where(kind: kind) : scope).order(:started_at, :id)
    end

    def stored_count(track) = Scrobble.where(user: @user).joins(:name_variant).where(name_variants: { track_name: track }).count
    def served_multiset = Smoke.served_plays.map { |p| [ p.played_at.to_i, p.artist, p.track ] }.tally

    # No run active for a few seconds in a row: the scheduler has nothing more that is due.
    def wait_until_quiet(what, timeout = 120)
      quiet_since = nil
      wait_for(what, timeout) do
        busy = ImportRun.active.where(user: @user).exists?
        quiet_since = busy ? nil : (quiet_since || Time.now)
        quiet_since && Time.now - quiet_since > 5
      end
    end

    def wait_for_runs(kind, count, timeout = 120)
      wait_for("#{count} finished #{kind} run(s)", timeout) { sync_runs(kind).where(state: %w[completed failed]).count >= count }
    end

    # Stored plays are exactly what Last.fm serves (plus `kept`: plays still stored while their
    # removal awaits review), windows are contiguous and committed, counts agree.
    def check_synced(label, kept: {})
      ws = windows
      contiguous = ws.each_cons(2).all? { |a, b| a.window_to == b.window_from } && ws.all? { |w| w.state == "committed" }
      counts = ws.all? { |w| w.committed_count == Scrobble.present.where(user: @user).played_between(w.window_from, w.window_to).count }
      want = served_multiset.merge(kept) { |_, x, y| x + y }
      diff = (want.keys | stored_multiset.keys).reject { |k| want[k] == stored_multiset[k] }
      check(label, contiguous && counts && diff.empty?,
            "contiguous #{contiguous}, counts #{counts}, #{diff.size} differing plays, #{ws.size} windows")
    end

    def check_runs_never_overlapped
      runs = ImportRun.where(user: @user).order(:started_at, :id).to_a
      overlapping = runs.each_cons(2).reject { |a, b| a.finished_at && a.finished_at <= b.started_at }
      check("never two runs at once for the account", overlapping.empty?, overlapping.map { |a, b| "#{a.kind}/#{b.kind}" }.join(", ").presence)
    end

    def import_and_settle!
      start_workers(recurring: true)
      orchestrator.start!(@user)
      wait_for_run("completed")
      check_complete
      sleep 4 # several ticks
      check("no sync during or straight after the import (not due)", sync_runs.none?, sync_runs.pluck(:kind).inspect)
    end

    # New plays must be older than the current minute: sync fetches whole minutes.
    def add_plays!(control)
      Smoke.write_control(control)
      newest = Array(control[:add]).map(&:first).max.to_i
      wait_for("the next minute") { Time.now.utc.beginning_of_minute.to_i > newest }
    end

    def sync_recurring
      scenario("recurring sync, catch-up and weekly comparison through the real scheduler") do
        reset!
        import_and_settle!
        old = Smoke.plays.find { |p| p.track == "Old 12" }
        fresh_at = [ Time.now.to_i - 5, windows.last.window_to.to_i ].max
        add_plays!(add: [ [ fresh_at, "Fresh" ], [ (Time.now - 3.days).to_i, "Offline" ], [ (Smoke.base + 2.months + 10.days).to_i, "Historical" ] ],
                   drop: [ [ old.played_at.to_i, "Old 12" ] ])
        frontier = windows.last.window_to

        time_passes!(31.minutes)
        wait_for_runs("sync", 1)
        wait_until_quiet("the sync")
        check("the sync stored the play after the import's cutoff, once", stored_count("Fresh") == 1)
        check("it didn't reach back past its 24-hour lookback", stored_count("Offline").zero? && stored_count("Historical").zero?)
        check("the current month's window grew; no window added", windows.last.window_to > frontier && windows.size == 5,
              "#{windows.size} windows, last ends #{windows.last.window_to}")
        check("last successful sync recorded", @user.lastfm_connection.reload.last_synced_at.present?)

        time_passes!(25.hours)
        wait_for_runs("catch_up", 1)
        wait_until_quiet("the catch-up")
        check("the daily catch-up stored the back-dated play", stored_count("Offline") == 1)

        time_passes!(7.days)
        wait_for_runs("reconcile", 1)
        wait_until_quiet("the weekly comparison")
        check("months whose counts differed were rechecked: the historical play added",
              stored_count("Historical") == 1 && sync_runs("reconcile").last.state == "completed", sync_runs("reconcile").last.last_error)
        dropped = Scrobble.where(user: @user, played_at: old.played_at).joins(:name_variant).where(name_variants: { track_name: "Old 12" })
        check("the deleted play is suspected, not removed", ScrobbleRemoval.where(user: @user).pluck(:state) == [ "observed" ] && dropped.present.count == 1)

        time_passes!(7.days)
        wait_for_runs("reconcile", 2)
        wait_until_quiet("the second weekly comparison")
        check("a second independent check proposes the removal for review",
              ScrobbleRemoval.where(user: @user).pluck(:state) == [ "pending_review" ] && Scrobble.where(user: @user).where.not(removed_at: nil).none?)
        stop_all
        check_synced("final history: exactly Last.fm's plays, the unreviewed deletion kept, no duplicates",
                     kept: { [ old.played_at.to_i, old.artist, old.track ] => 1 })
        check_runs_never_overlapped
        health = HistoryImport::SyncHealth.for(@user)
        check("health: import complete, a pending removal, nothing stopped",
              health[:importComplete] && health[:reviews][:pendingRemovals] == 1 && health[:problemPeriods].empty?, health.slice(:periods, :reviews).inspect)
        check("the recurring sync task ran under the scheduler", SolidQueue::RecurringExecution.where(task_key: "history_sync").exists?)
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
      end
    end

    def sync_crash_restart
      scenario("a worker killed mid-sync: the sync resumes after recovery and applies once") do
        reset!
        import_and_settle!
        add_plays!(add: [ [ [ Time.now.to_i - 5, windows.last.window_to.to_i ].max, "Fresh" ] ])
        Smoke.write_control(Smoke.control.merge("delay" => 2))
        time_passes!(31.minutes)
        wait_for("the sync to fetch") { sync_runs("sync").exists? && recent_requests.any? { |r| r["at"] > sync_runs("sync").last.started_at.to_f } }
        stop_all(:KILL)
        check("killed before the sync finished", sync_runs("sync").last.state == "running")
        Smoke.write_control(Smoke.control.except("delay"))
        time_passes!(HistoryImport::Recovery::STALL_AFTER + ImportWindow::LEASE + 60)
        start_workers(recurring: true)
        wait_for("the sync to finish") { sync_runs("sync").first.reload.state == "completed" }
        wait_until_quiet("recovery")
        stop_all
        check("the new play stored once", stored_count("Fresh") == 1)
        check_synced("history intact after the crash")
        check_runs_never_overlapped
      end
    end

    def sync_outage
      scenario("an outage and rate limiting during sync: bounded retries, nothing lost, then caught up") do
        reset!
        import_and_settle!
        before = Scrobble.where(user: @user).pluck(:id, :seq, :name_variant_id).sort
        add_plays!(add: [ [ [ Time.now.to_i - 5, windows.last.window_to.to_i ].max, "Fresh" ] ])
        Smoke.write_control(Smoke.control.merge("fail_all" => true))
        time_passes!(31.minutes)
        wait_for("the sync to start") { sync_runs("sync").exists? }
        requests = recent_requests.size
        8.times do
          time_passes!(6.hours + 60) # past every retry delay in turn
          sleep 3
        end
        wait_for("the sync to give up") { sync_runs("sync").first.reload.state == "failed" }
        check("bounded: the sync gave up after a limited number of requests", recent_requests.size - requests <= 60,
              "#{recent_requests.size - requests} requests")
        check("nothing lost or changed", Scrobble.where(user: @user).pluck(:id, :seq, :name_variant_id).sort == before)
        check("the connection isn't failed by a temporary outage", @user.lastfm_connection.reload.history_state == "imported")
        # Stopped, or already being tried again by the next due run (the hours shifted above passed
        # rearm_after): never synchronised.
        status = HistoryImport::SyncStatus.for(@user).last.status
        check("the period is never reported as synchronised", %i[check_stopped checking].include?(status), status.inspect)
        check("the failed sync is reported", sync_runs("sync").first.last_error.to_s.include?("need attention"), sync_runs("sync").first.last_error)

        Smoke.write_control(Smoke.control.except("fail_all").merge("rate_limited" => true))
        time_passes!(25.hours) # catch-up due; the period that gave up may be tried again
        wait_for("a run to meet the rate limit") { sync_runs.where("started_at > ?", sync_runs("sync").first.started_at).exists? }
        sleep 4
        Smoke.write_control(Smoke.control.except("rate_limited"))
        # Periods that gave up during the outage are tried again only once rearm_after has passed
        # since they stopped (and syncs carry on meanwhile, creating periods that may give up too).
        # Move past it before asserting the catch-up; then let retries and due syncs run.
        time_passes!(HistoryImport::Sync.config[:rearm_after] + 1.hour)
        6.times do
          time_passes!(2.hours)
          sleep 3
        end
        wait_until_quiet("catching up")
        stop_all
        periods = windows.map { |w| [ w.window_from.utc.iso8601, w.state, w.review_reason, w.retry_at&.utc&.iso8601 ] }
        check("caught up once Last.fm answered: the play stored once", stored_count("Fresh") == 1, periods.reject { |p| p[1] == "committed" }.inspect)
        check_synced("history complete after the outage")
        check_runs_never_overlapped
      end
    end

    def sync_stuck_period
      scenario("a period stuck on a row Last.fm can't date: an explicit gap, and later listening carries on") do
        reset!
        import_and_settle!
        bad = [ Time.now.to_i - 10, windows.last.window_to.to_i ].max
        add_plays!(undated_at: bad, add: [ [ bad + 1, "Next to the bad row" ] ])
        time_passes!(31.minutes)
        wait_for_runs("sync", 1)
        wait_until_quiet("the first sync")
        current = windows.last
        check("the current month's check stopped for a person, its imported plays kept",
              current.state == "needs_review" && current.review_reason == "undated_rows" && current.committed_at.present?,
              [ current.state, current.review_reason ].inspect)
        check("counted as needing attention", HistoryImport::Attention.for(@user)[:total] == 1)

        # The next sync detaches the stopped check's new range; that range holds the bad row too, and
        # is too short to split: it becomes an explicit gap.
        time_passes!(31.minutes)
        wait_for_runs("sync", 2)
        wait_until_quiet("the second sync")
        gaps = HistoryImport::SyncHealth.for(@user)[:missingPeriods]
        check("the range holding the bad row is an explicit gap, under 2 hours", gaps.size == 1 && gaps.first[:state] == "needs_review" &&
              Time.zone.parse(gaps.first[:to]) - Time.zone.parse(gaps.first[:from]) < 2.hours, gaps.inspect)

        later = Time.now.to_i + 2
        Smoke.write_control(Smoke.control.merge("add" => Smoke.control["add"] + [ [ later, "Later listening" ] ]))
        wait_for("the next minute") { Time.now.utc.beginning_of_minute.to_i > later }
        time_passes!(31.minutes)
        wait_for_runs("sync", 3)
        wait_until_quiet("the third sync")
        stop_all
        check("later listening was stored, past the gap", stored_count("Later listening") == 1)
        check("the play in the gap is waiting, not lost or guessed", stored_count("Next to the bad row").zero?)
        check("coverage is reported as partial across the gap, never complete",
              ImportCoverage.status_for(@user, windows.first.window_from, windows.last.window_to) == :partial)
        check("no failed jobs", failed_jobs.empty?, failed_jobs.inspect)
      end
    end

    # Stage 2.9: a complete import of a large synthetic history (SMOKE_PLAYS) through real Solid
    # Queue workers, paused and resumed partway, then a worker killed outright and recovered by the
    # watchdog. Not part of `all`: run it by name.
    def large_import
      scenario("large synthetic import through real Solid Queue: pause, resume, a killed worker, recovery") do
        raise "set SMOKE_PLAYS (see test/benchmark/history_benchmark.rb)" unless Smoke.large?

        reset!
        expected = Smoke.large_plays.group_by { |row| Time.at(row.first).utc.strftime("%Y-%m") }.transform_values(&:size)
        peak_connections = 0
        peak_worker_mb = 0
        sampler = Thread.new do
          loop do
            n = ActiveRecord::Base.connection_pool.with_connection do |c|
              c.select_value("SELECT count(*) FROM pg_stat_activity WHERE datname = current_database()").to_i
            end
            peak_connections = [ peak_connections, n ].max
            # Resident memory of the Solid Queue processes (supervisor, dispatcher, workers, scheduler).
            rss = `ps -axo rss=,command=`.lines.select { |l| l.include?("solid-queue") }.sum { |l| l.to_i } / 1024
            peak_worker_mb = [ peak_worker_mb, rss ].max
            sleep 1
          end
        end
        started = Time.now
        start_workers(recurring: true)
        orchestrator.start!(@user)
        committed = -> { ImportWindow.where(user: @user, state: "committed").count }
        wait_for("a fifth of the periods", 900) { committed.call >= 50 }
        orchestrator.pause!(run)
        wait_for("the run to pause", 60) { run.state == "paused" }
        # The step already running finishes its period (commits are atomic); then nothing more.
        quiet = (1..15).any? { idle?(4) }
        check("paused: once the running step finished, nothing more is fetched", quiet)
        orchestrator.resume!(run)
        wait_for("half the periods", 900) { committed.call >= 130 }
        stop_all(:KILL)
        check("a worker killed mid-import", run.state == "running", run.state)
        time_passes!(HistoryImport::Recovery::STALL_AFTER + ImportWindow::LEASE + 60)
        start_workers(recurring: true)
        wait_for_run("completed", timeout: 3600)
        elapsed = (Time.now - started).round
        wait_for("catalogue matching", 1800) { NameVariant.where(match_version: nil).none? }
        matched_after = (Time.now - started).round - elapsed
        stop_all
        sampler.kill

        stored = Scrobble.where(user: @user)
        actual = stored.group(Arel.sql("to_char(played_at AT TIME ZONE 'UTC', 'YYYY-MM')")).count
        requests = Smoke.requests
        check("every play stored once (#{Smoke.large_plays.size})", stored.count == Smoke.large_plays.size, "#{stored.count} stored")
        check("every month exact", actual == expected, (expected.keys | actual.keys).reject { |k| expected[k] == actual[k] }.first(3).inspect)
        check("same-second plays kept in their own slots", stored.where("seq > 0").exists?)
        check("coverage complete, progress 100%", HistoryImport::Progress.for(@user).then { |p| p.complete && p.percent == 100 })
        check("no staging left", ImportWindowRow.none?)
        killed = %w[SolidQueue::Processes::ProcessPrunedError SolidQueue::Processes::ProcessMissingError]
        others = failed_jobs.reject { |_, error| killed.include?(error["exception_class"]) }
        check("the only failed jobs are those of the killed worker", others.empty?, others.first(3).inspect)
        check("measured", true, "#{elapsed}s import, #{matched_after}s more for matching, " \
                                "#{requests.count { |r| r['method'] == 'user.getRecentTracks' }} recent-tracks requests, " \
                                "peak #{peak_connections} database connections, peak #{peak_worker_mb} MB across Solid Queue processes")
      end
    end

    def sync_storage_disabled
      scenario("storage off: due syncs are never started by the scheduler") do
        reset!
        import_and_settle!
        stop_all
        add_plays!(add: [ [ [ Time.now.to_i - 5, windows.last.window_to.to_i ].max, "Fresh" ] ])
        requests = Smoke.requests.size
        start_workers(storage: false, recurring: true)
        time_passes!(31.minutes)
        wait_for("ticks with storage off") { SolidQueue::Job.where(class_name: "SyncScheduleJob").where.not(finished_at: nil).count >= 3 }
        check("no sync started, nothing fetched", sync_runs.none? && Smoke.requests.size == requests)
        stop_all
        start_workers(recurring: true)
        wait_for_runs("sync", 1)
        wait_until_quiet("the sync")
        stop_all
        check("storage back on: the sync ran and stored the play once", stored_count("Fresh") == 1)
      end
    end

    def all = %i[configuration full_import duplicate_delivery kill_during_fetch crash_around_commit graceful_restart scheduled_retry
                 pause_resume_cancel storage_disabled reconciliation slow_healthy_worker
                 sync_recurring sync_crash_restart sync_outage sync_stuck_period sync_storage_disabled]
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
