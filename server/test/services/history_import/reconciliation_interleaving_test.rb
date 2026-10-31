require "test_helper"

# Reconciliation under forced interleavings. Each worker is a thread with its own database
# connection (like a separate process) and stops at named checkpoints until the test lets it go,
# so every ordering below happens deterministically, not by chance. A trace records what each
# worker saw and did; it is printed when an assertion fails. Synthetic data only.
class HistoryImport::ReconciliationInterleavingTest < ActiveSupport::TestCase
  include HistoryHelpers
  include ImportHelpers

  self.use_transactional_tests = false

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze
  T = Time.utc(2014, 3, 15, 20) # a second with identical plays
  U = Time.utc(2014, 3, 20, 9)
  NEW = Time.utc(2014, 3, 3, 12)
  WAIT = 10 # seconds before a checkpoint that is never reached fails the test instead of hanging it

  # Checkpoints shared by the test and its workers. A worker calls `reach`; at a point the test
  # chose to pause, it then waits for `release`.
  class Checkpoints
    def initialize
      @mutex = Mutex.new
      @queues = {}
      @pauses = Set.new
    end

    def pause_at(*names) = @mutex.synchronize { @pauses.merge(names) }

    def reach(name)
      queue(:arrived, name) << true
      paused = @mutex.synchronize { @pauses.include?(name) }
      queue(:release, name).pop(timeout: WAIT) || raise("checkpoint #{name} was never released") if paused
    end

    def wait_for(name) = queue(:arrived, name).pop(timeout: WAIT) || raise("checkpoint #{name} was never reached")
    def release(name) = queue(:release, name) << true

    private

    def queue(kind, name) = @mutex.synchronize { @queues[[ kind, name ]] ||= Queue.new }
  end

  class Trace
    def initialize
      @mutex = Mutex.new
      @events = []
    end

    def record(worker, what, value) = @mutex.synchronize { @events << [ worker, what, value ] }
    def values(worker, what) = @mutex.synchronize { @events.select { |w, k, _| w == worker && k == what }.map(&:last) }
    def to_s = @mutex.synchronize { @events.map { |w, k, v| "#{w} #{k}: #{v.inspect}" }.join("\n") }
  end

  # WindowCommitter with checkpoints where interleavings matter, recording the snapshot it read
  # and whether it won the claim.
  class TracedCommitter < HistoryImport::WindowCommitter
    def initialize(name:, points:, trace:, **options)
      super(**options)
      @name = name
      @points = points
      @trace = trace
    end

    private

    def claim
      @points.reach("#{@name}:before_claim")
      super.tap do |won|
        @trace.record(@name, :claimed, won)
        @points.reach("#{@name}:claimed") if won
      end
    end

    # Inside the commit transaction, holding the window's row lock and the per-user lock.
    def staged_rows(window)
      super.tap do |rows|
        @trace.record(@name, :snapshot, rows.map { |r| [ r.played_at.to_i, r.track_name ] }.sort)
        @points.reach("#{@name}:read_snapshot")
      end
    end
  end

  # WindowValidator that stops after both reads agreed, before it stages the snapshot.
  class TracedValidator < HistoryImport::WindowValidator
    def initialize(name:, points:, trace:, **options)
      super(**options)
      @name = name
      @points = points
      @trace = trace
    end

    private

    def validated(fetch, matching_fetch, snapshot, conflicts = [])
      @trace.record(@name, :validated_snapshot, snapshot.entries.map { |e| [ e.played_at.to_i, e.track ] }.sort)
      @points.reach("#{@name}:validated")
      super
    end
  end

  setup do
    @user = history_user("interleave-#{SecureRandom.hex(3)}")
    @window = window(@user, from: MARCH[0], to: MARCH[1])
    @variants_before = NameVariant.maximum(:id).to_i
    @points = Checkpoints.new
    @trace = Trace.new
    @pids = {}
    @subscription = ActiveSupport::Notifications.subscribe(HistoryImport::Reconciler::EVENT) do |*, payload|
      worker = Thread.current[:interleave_worker] || "main"
      @trace.record(worker, :intended, payload[:intended].map { |r| [ r[:played_at].to_i, r[:seq], r[:name_variant_id] ] })
      @trace.record(worker, :inserted_ids, payload[:inserted_ids])
    end
    @t0 = Time.current.change(usec: 0)
  end

  teardown do
    ActiveSupport::Notifications.unsubscribe(@subscription)
    @user.destroy!
    NameVariant.where("id > ?", @variants_before).delete_all
  end

  def late = @t0 + ImportWindow::LEASE + 1.minute

  def worker(name)
    Thread.new do
      Thread.current[:interleave_worker] = name
      Thread.current.report_on_exception = false
      ActiveRecord::Base.connection_pool.with_connection do |connection|
        @pids[name] = connection.select_value("SELECT pg_backend_pid()")
        yield
      end
    end
  end

  def finish(thread) = (thread.join(WAIT) || raise("worker did not finish")).value

  def committer(name, clock: @t0) = TracedCommitter.new(name: name, points: @points, trace: @trace, window: ImportWindow.find(@window.id), clock: -> { clock })

  def commit_in(name, clock: @t0) = worker(name) { committer(name, clock: clock).call.status }

  # Waits until the worker's connection is blocked on a lock held by another transaction.
  def wait_until_blocked(name)
    deadline = Time.now + WAIT
    until (pid = @pids[name]) &&
          ActiveRecord::Base.connection.select_value("SELECT wait_event_type FROM pg_stat_activity WHERE pid = #{Integer(pid)}") == "Lock"
      raise "#{name} never waited for the lock" if Time.now > deadline

      Thread.pass
    end
  end

  def base = [ entry(T, "A"), entry(T, "A"), entry(T, "B"), entry(U, "U") ]

  # The month committed once already, so later snapshots are reconciled with it.
  def commit_base!
    stage!(@window.reload, base, at: @t0)
    assert_equal :committed, HistoryImport::WindowCommitter.new(window: @window, clock: -> { @t0 }).call.status
  end

  def stored_multiset = Scrobble.where(user: @user).joins(:name_variant).order(:played_at, :seq).pluck(:played_at, :seq, "name_variants.track_name").map { |at, seq, t| [ at.to_i, seq, t ] }

  def month
    w = @window.reload
    { state: w.state, claim_token: w.claim_token, committed_count: w.committed_count, last_check_fetch_id: w.last_check_fetch_id,
      present: Scrobble.present.where(user: @user).count, status: HistoryImport::SyncStatus.for(@user).sole.status,
      staging_left: ImportWindowRow.where(import_window_fetch_id: w.fetches.select(:id)).count }
  end

  # The invariants for a reconciled month, checked against the snapshot that was committed.
  def assert_reconciled(expected_multiset)
    actual = stored_multiset
    assert_equal expected_multiset, actual, "stored plays\n#{@trace}"
    assert_equal actual.size, actual.uniq.size, "no slot used twice"
    m = month
    assert_equal "committed", m[:state], @trace.to_s
    assert_nil m[:claim_token]
    assert_equal m[:present], m[:committed_count], "committed count agrees with the plays present"
    assert_equal 0, m[:staging_left], "no staging left"
  end

  test "two workers committing the same month at the same moment: one applies it once, the other does nothing" do
    commit_base!
    fetch = stage!(@window.reload, base + [ entry(T, "A"), entry(NEW, "New") ], at: @t0)
    @points.pause_at("a:before_claim", "b:before_claim")
    threads = %w[a b].map { |name| commit_in(name) }
    %w[a b].each { |name| @points.wait_for("#{name}:before_claim") }
    %w[a b].each { |name| @points.release("#{name}:before_claim") }
    outcomes = threads.map { |t| finish(t) }

    assert_equal %i[committed not_claimed], outcomes.sort, @trace.to_s
    winner = outcomes.index(:committed).then { |i| %w[a b][i] }
    loser = (%w[a b] - [ winner ]).sole
    assert_equal [ true ], @trace.values(winner, :claimed)
    assert_equal [ false ], @trace.values(loser, :claimed)
    assert_empty @trace.values(loser, :snapshot), "the loser never read the snapshot"
    assert_equal [ [ [ NEW.to_i, "New" ], [ T.to_i, "A" ], [ T.to_i, "A" ], [ T.to_i, "A" ], [ T.to_i, "B" ], [ U.to_i, "U" ] ] ],
                 @trace.values(winner, :snapshot)
    intended = @trace.values(winner, :intended).sole
    assert_equal [ [ NEW.to_i, 0 ], [ T.to_i, 3 ] ], intended.map { |at, seq, _| [ at, seq ] }.sort, "a third identical play goes after the last slot"
    assert_equal intended.size, @trace.values(winner, :inserted_ids).sole.size
    assert_reconciled([ [ NEW.to_i, 0, "New" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ T.to_i, 2, "B" ], [ T.to_i, 3, "A" ], [ U.to_i, 0, "U" ] ])
    assert_equal fetch.id, month[:last_check_fetch_id]
    assert_equal :synchronized, month[:status]
  end

  test "a worker that read the window before another committed it cannot commit it again" do
    commit_base!
    stage!(@window.reload, base + [ entry(NEW, "New") ], at: @t0)
    @points.pause_at("b:before_claim")
    b = commit_in("b") # has loaded the window, still `validated`
    @points.wait_for("b:before_claim")
    assert_equal :committed, finish(commit_in("a"))
    after_a = stored_multiset
    @points.release("b:before_claim")

    assert_equal :not_claimed, finish(b)
    assert_equal after_a, stored_multiset, "nothing changed after the winner finished"
    assert_empty @trace.values("b", :intended)
    assert_reconciled([ [ NEW.to_i, 0, "New" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ T.to_i, 2, "B" ], [ U.to_i, 0, "U" ] ])
  end

  test "a worker whose lease ran out before it wrote is taken over, and its late write is refused" do
    commit_base!
    stage!(@window.reload, base + [ entry(NEW, "New") ], at: @t0)
    @points.pause_at("a:claimed")
    a = commit_in("a", clock: @t0)
    @points.wait_for("a:claimed") # a holds the lease, then stalls past its expiry

    assert_equal :committed, finish(commit_in("b", clock: late)), "b took the expired lease over"
    @points.release("a:claimed")

    assert_equal :stale, finish(a), "a's lease is gone; it writes nothing"
    assert_empty @trace.values("a", :snapshot)
    assert_empty @trace.values("a", :intended)
    assert_equal 1, @trace.values("b", :intended).sole.size
    assert_reconciled([ [ NEW.to_i, 0, "New" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ T.to_i, 2, "B" ], [ U.to_i, 0, "U" ] ])
  end

  test "a worker whose lease runs out while it holds the month keeps it; the next worker waits, then finds it committed" do
    commit_base!
    stage!(@window.reload, base + [ entry(NEW, "New") ], at: @t0)
    @points.pause_at("a:read_snapshot")
    a = commit_in("a", clock: @t0)
    @points.wait_for("a:read_snapshot") # inside the transaction, row and user locks held

    b = commit_in("b", clock: late) # sees an expired lease, but must wait for a's row lock
    wait_until_blocked("b")
    @points.release("a:read_snapshot")

    assert_equal [ :committed, :not_claimed ], [ finish(a), finish(b) ], @trace.to_s
    assert_equal [ false ], @trace.values("b", :claimed)
    assert_reconciled([ [ NEW.to_i, 0, "New" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ T.to_i, 2, "B" ], [ U.to_i, 0, "U" ] ])
  end

  test "two validated snapshots with different new plays: only the committed one is applied; the stale validator is refused" do
    fake = FakeRecentTracks.new([ T, T, U ].zip(%w[A A U]).map { |at, t| play(at, t) }).install(self)
    validate = lambda do |name, clock|
      TracedValidator.new(name: name, points: @points, trace: @trace, window: ImportWindow.find(@window.id), client: stub_client,
                          username: "listener", clock: -> { clock }).call.status
    end
    assert_equal :validated, validate.("setup", @t0)
    assert_equal :committed, HistoryImport::WindowCommitter.new(window: @window.reload, clock: -> { @t0 }).call.status

    @window.reload.update!(state: "pending", attempts: 0, validated_at: nil, fetched_count: nil, expected_total: nil)
    fake.add(play(NEW, "X"))
    @points.pause_at("a:validated")
    a = worker("a") { validate.("a", @t0) }
    @points.wait_for("a:validated") # a has two agreeing reads with X, not yet staged; then it stalls

    fake.remove_if { |p| p.track == "X" }
    fake.add(play(NEW + 60, "Y"))
    assert_equal :validated, finish(worker("b") { validate.("b", late) }), "b took the expired lease over"
    assert_equal :committed, finish(worker("b-commit") { HistoryImport::WindowCommitter.new(window: ImportWindow.find(@window.id), clock: -> { late }).call.status })
    @points.release("a:validated")

    assert_equal :stale, finish(a), "a's snapshot is never staged"
    assert_includes @trace.values("a", :validated_snapshot).sole, [ NEW.to_i, "X" ]
    assert_includes @trace.values("b", :validated_snapshot).sole, [ (NEW + 60).to_i, "Y" ]
    assert_reconciled([ [ NEW.to_i + 60, 0, "Y" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ U.to_i, 0, "U" ] ])
    a_fetches = @window.fetches.where("attempt > 2").order(:attempt).first(2)
    assert_equal %w[failed failed], a_fetches.map(&:outcome), "a's reads are kept for audit, closed as abandoned"
  end

  test "retrying after a successful commit changes nothing, and replaying the snapshot is not a second observation" do
    commit_base!
    snapshot = [ entry(T, "A"), entry(T, "A"), entry(NEW, "New") ] # B and U missing
    fetch = stage!(@window.reload, snapshot, at: @t0)
    staged = fetch.rows.map { |r| r.attributes.except("id") }
    first = committer("a")
    assert_equal :committed, first.call.status
    after = [ stored_multiset, ScrobbleRemoval.order(:id).pluck(:scrobble_id, :state), ReviewDecision.count ]
    assert_equal %w[observed observed], after[1].map(&:last)

    assert_equal :not_claimed, first.call.status, "the same worker retrying"
    assert_equal :not_claimed, finish(commit_in("b")), "a redelivered job"
    ImportWindowRow.insert_all!(staged) # the same snapshot committed again, as a crash recovery would
    @window.reload.update!(state: "validated", validated_at: @t0, fetched_count: staged.size, expected_total: staged.size)
    assert_equal :committed, finish(commit_in("replay"))
    assert_equal after, [ stored_multiset, ScrobbleRemoval.order(:id).pluck(:scrobble_id, :state), ReviewDecision.count ]
    assert_empty @trace.values("replay", :intended).sole

    stage!(@window.reload, snapshot, at: @t0) # a later, separate validation
    assert_equal :committed, finish(commit_in("next"))
    assert_equal %w[pending_review pending_review], ScrobbleRemoval.order(:id).pluck(:state)
    assert_reconciled([ [ NEW.to_i, 0, "New" ], [ T.to_i, 0, "A" ], [ T.to_i, 1, "A" ], [ T.to_i, 2, "B" ], [ U.to_i, 0, "U" ] ])
    assert_equal :differences, month[:status]
  end

  # Random snapshots, four competing workers per round, every invariant checked against a model
  # of the rules after each round. STRESS_ROUNDS raises the count.
  test "stress: competing reconciliations of random snapshots keep every invariant" do
    random = Random.new(Integer(ENV.fetch("STRESS_SEED", "2024")))
    seconds = Array.new(6) { |i| Time.utc(2014, 3, 10 + i, 8) }
    tracks = %w[P Q R]
    commit_base!
    Integer(ENV.fetch("STRESS_ROUNDS", "12")).times do |round|
      # Ordered, so a seed always reproduces the same rounds.
      before = Scrobble.where(user: @user).joins(:name_variant).order(:played_at, :seq).pluck(:played_at, "name_variants.track_name").map { |at, t| [ at.to_i, t ] }
      # Last.fm now: most stored plays (some missing), plus a few new ones, duplicates included.
      # Every 10th round lacks most of them, as an incomplete answer would.
      keep = (round % 10 == 9) ? 0.3 : 0.9
      snapshot = before.select { random.rand < keep }.map { |at, track| entry(Time.at(at).utc, track) }
      snapshot += Array.new(random.rand(0..4)) { entry(seconds.sample(random: random), tracks.sample(random: random)) }
      stage!(@window.reload, snapshot, at: @t0)
      @points = Checkpoints.new
      names = Array.new(4) { |i| "r#{round}w#{i}" }
      @points.pause_at(*names.map { |n| "#{n}:before_claim" })
      threads = names.map { |n| commit_in(n) }
      names.each { |n| @points.wait_for("#{n}:before_claim") }
      names.shuffle(random: random).each { |n| @points.release("#{n}:before_claim") }
      outcomes = threads.map { |t| finish(t) }
      assert_equal 3, outcomes.count(:not_claimed), "round #{round}: #{outcomes.inspect}\n#{@trace}"

      # The guard: a snapshot lacking more than half of 20 or more stored plays goes to review, and
      # nothing changes. (Nothing is removed here, so every stored play is present.)
      lacking = before.tally.sum { |play, n| [ n - snapshot.map { |e| [ e.played_at.to_i, e.track ] }.count(play), 0 ].max }
      if before.size >= HistoryImport::Reconciler::MASS_DISAPPEARANCE_MIN && lacking * 2 > before.size
        assert_equal [ :needs_review ], outcomes - [ :not_claimed ], "round #{round}: guarded"
        assert_equal before.sort, Scrobble.where(user: @user).joins(:name_variant).pluck(:played_at, "name_variants.track_name").map { |at, t| [ at.to_i, t ] }.sort
        @window.reload.update!(state: "committed", last_error_message: nil) # a person looked and let it be checked again
        next
      end
      assert_equal 1, outcomes.count(:committed), "round #{round}: #{outcomes.inspect}\n#{@trace}"

      # The model: per second, identical plays pair up; leftovers on both sides leave it unchanged.
      expected = (before + snapshot.map { |e| [ e.played_at.to_i, e.track ] }).group_by(&:first).flat_map do |t, _|
        had = before.select { |at, _| at == t }.map(&:last).tally
        got = snapshot.select { |e| e.played_at.to_i == t }.map(&:track).tally
        extra_stored = had.any? { |k, n| n > got.fetch(k, 0) }
        extra_fetched = got.any? { |k, n| n > had.fetch(k, 0) }
        merged = extra_stored && extra_fetched ? had : had.merge(got) { |_, x, y| [ x, y ].max }
        merged.flat_map { |k, n| [ [ t, k ] ] * n }
      end
      actual = Scrobble.where(user: @user).joins(:name_variant).pluck(:played_at, "name_variants.track_name").map { |at, t| [ at.to_i, t ] }
      assert_equal expected.sort, actual.sort, "round #{round}\n#{@trace}"
      m = month
      assert_equal [ "committed", m[:present] ], [ m[:state], m[:committed_count] ], "round #{round}"
      assert_equal 0, m[:staging_left]
      open_now = ReconciliationDispute.open.where(user: @user).pluck(:played_at).map(&:to_i)
      assert_equal open_now.size, open_now.uniq.size, "one open dispute per second"
      assert_not_equal :synchronized, m[:status], "round #{round}: differences remain" if open_now.any?
      winner = names[outcomes.index(:committed)]
      assert_equal @trace.values(winner, :intended).sole.size, @trace.values(winner, :inserted_ids).sole.size
    end
  end
end
