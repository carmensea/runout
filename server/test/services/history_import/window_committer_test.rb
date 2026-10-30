require "test_helper"

# Stage 2.4: committing validated windows into `scrobbles`. Synthetic data only.
class HistoryImport::WindowCommitterTest < ActiveSupport::TestCase
  include HistoryHelpers

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze
  APRIL = [ Time.utc(2014, 4, 1), Time.utc(2014, 5, 1) ].freeze

  setup do
    @user = history_user
    @window = window(@user, from: MARCH[0], to: MARCH[1])
  end

  def commit(window = @window, **options) = HistoryImport::WindowCommitter.new(window: window, **options).call

  def plays(count, from: Time.utc(2014, 3, 10))
    Array.new(count) { |i| entry(from + (i * 60), "Track #{i}", artist: "Artist #{i % 7}") }
  end

  def stored(user = @user) = Scrobble.where(user: user)

  def staged(window = @window) = ImportWindowRow.where(import_window_fetch_id: window.fetches.select(:id))

  # Replaces Scrobble.insert_all! for the duration of the block. `fail_on` names the call that raises.
  def failing_inserts(fail_on:, error: ActiveRecord::StatementInvalid.new("simulated failure\nDETAIL: Failing row contains (secret)"))
    calls = 0
    Scrobble.define_singleton_method(:insert_all!) do |*args, **options|
      calls += 1
      raise error if calls == fail_on

      super(*args, **options)
    end
    yield
  ensure
    Scrobble.singleton_class.remove_method(:insert_all!)
  end

  test "a validated window is committed with exact strings, UTC times and its own IDs" do
    at = Time.utc(2014, 3, 15, 20, 0, 0)
    stage!(@window, [ entry(at, "Hoppípolla", artist: "  Sigur Rós ", album: "", artist_mbid: "mbid-1"),
                      entry(at + 60, "Track 2", album: "Album") ])
    run = ImportRun.create!(user: @user, kind: "full", state: "running")
    @window.update!(import_run: run)

    result = commit
    assert_equal :committed, result.status, result.detail
    plays = stored.order(:played_at).to_a
    assert_equal 2, plays.size
    first = plays.first.name_variant
    assert_equal [ "  Sigur Rós ", "Hoppípolla", "", "mbid-1" ], [ first.artist_name, first.track_name, first.album_name, first.artist_mbid ]
    assert_equal at, plays.first.played_at
    assert_equal "UTC", plays.first.played_at.zone
    assert_equal [ 0, 0 ], plays.map(&:seq)
    assert plays.all? { |p| p.id.is_a?(Integer) }, "scrobbles get their own internal IDs"
    assert_nil first.artist_id, "no canonical match is forced"

    w = @window.reload
    assert_equal [ "committed", 2, nil, nil ], [ w.state, w.committed_count, w.claim_token, w.lease_expires_at ]
    assert w.committed_at
    assert_equal plays.first.first_seen_fetch_id, w.fetches.where(outcome: "validated").maximum(:id)
    assert_equal 2, run.reload.committed_scrobbles
    assert_equal 0, staged.count, "staging is removed once the commit is confirmed"
    assert w.fetches.exists?, "fetch records stay for audit"
  end

  test "an empty month commits explicitly and counts as complete coverage" do
    stage!(@window, [])
    assert_equal :committed, commit.status
    assert_equal [ "committed", 0 ], [ @window.reload.state, @window.committed_count ]
    assert_equal 0, stored.count
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH)
  end

  test "identical plays in the same second are kept as separate scrobbles" do
    at = Time.utc(2014, 3, 15, 20)
    stage!(@window, [ entry(at, "Same"), entry(at, "Other"), entry(at, "Same"), entry(at, "Same") ])
    assert_equal :committed, commit.status
    rows = stored.order(:seq).includes(:name_variant).to_a
    assert_equal [ 0, 1, 2, 3 ], rows.map(&:seq)
    assert_equal %w[Same Other Same Same], rows.map { |r| r.name_variant.track_name }, "seq follows the validated snapshot's order"
    assert_equal 2, rows.map(&:name_variant_id).uniq.size, "identical plays share one immutable variant"
  end

  test "existing name variants are reused, never duplicated or changed" do
    existing = variant(track: "Track", artist: "Artist", album: "Album", artist_mbid: "", track_mbid: "", album_mbid: "")
    stage!(@window, [ entry(Time.utc(2014, 3, 2), "Track") ])
    assert_no_difference -> { NameVariant.count } do
      assert_equal :committed, commit.status
    end
    assert_equal existing.id, stored.sole.name_variant_id
  end

  test "committing again creates no extra plays" do
    stage!(@window, plays(5))
    assert_equal :committed, commit.status
    assert_no_difference -> { Scrobble.count } do
      assert_equal :not_claimed, commit.status
      assert_equal :not_claimed, commit.status
    end
    assert_equal 5, @window.reload.committed_count
  end

  test "a window whose range already holds plays is left for review, not merged or duplicated" do
    stage!(@window, plays(3))
    commit
    # Force the same snapshot through again, as a bug or a manual reset might.
    @window.reload.update!(state: "validated", committed_at: nil, committed_count: nil)
    stage!(@window, plays(3))
    assert_no_difference -> { Scrobble.count } do
      result = commit
      assert_equal :needs_review, result.status
      assert_match "already stored", result.detail
    end
    assert_equal "needs_review", @window.reload.state
    assert_equal 3, staged.count, "review keeps the staging"
  end

  test "the database itself rejects a duplicate play identity" do
    stage!(@window, plays(1))
    commit
    original = stored.sole
    assert_db_rejects(ActiveRecord::RecordNotUnique) do
      Scrobble.insert_all!([ { user_id: @user.id, played_at: original.played_at, seq: 0, name_variant_id: original.name_variant_id } ])
    end
  end

  test "a database failure mid-insert rolls everything back and leaves the window retryable" do
    stage!(@window, plays(1_500)) # two insert batches
    result = failing_inserts(fail_on: 2) { commit }
    assert_equal :failed, result.status
    assert_equal 0, stored.count, "the first batch was rolled back too"
    assert_equal 0, NameVariant.count, "variants inserted in the failed transaction are gone"
    w = @window.reload
    assert_equal [ "validated", nil, nil, nil ], [ w.state, w.committed_at, w.committed_count, w.claim_token ]
    assert_match "simulated failure", w.last_error_message
    assert_no_match "secret", w.last_error_message, "only the first line of a database error is kept"
    assert_equal 1_500, staged.count, "staging survives for the retry"

    assert_equal :committed, commit.status
    assert_equal 1_500, stored.count
    assert_nil @window.reload.last_error_message
  end

  test "a crash mid-commit leaves nothing behind, and the window is committed once the lease expires" do
    stage!(@window, plays(1_500))
    crash = Class.new(Exception) # rubocop:disable Lint/InheritException -- stands in for a killed process
    assert_raises(crash) { failing_inserts(fail_on: 2, error: crash.new) { commit } }
    assert_equal 0, stored.count
    w = @window.reload
    assert_equal "committing", w.state, "the worker died holding its lease"
    assert_equal 1_500, staged.count

    assert_equal :not_claimed, commit.status, "nobody takes over while the lease is valid"
    later = Time.current + ImportWindow::LEASE + 1.minute
    assert_equal :committed, commit(clock: -> { later }).status
    assert_equal 1_500, stored.count
  end

  test "a worker whose lease expired or was taken over writes nothing" do
    { "taken over" => ->(id) { ImportWindow.where(id: id).update_all(claim_token: SecureRandom.uuid) },
      "expired" => ->(id) { ImportWindow.where(id: id).update_all(lease_expires_at: 1.minute.ago) } }.each do |name, interfere|
      w = window(@user, from: name == "expired" ? APRIL[0] : Time.utc(2014, 5, 1), to: name == "expired" ? APRIL[1] : Time.utc(2014, 6, 1))
      stage!(w, plays(2, from: w.window_from + 60))
      committer = HistoryImport::WindowCommitter.new(window: w)
      committer.define_singleton_method(:claim) { super().tap { interfere.(w.id) } }
      assert_equal :stale, committer.call.status, name
      assert_equal 0, stored.count, name
      assert_equal [ "committing", 2 ], [ w.reload.state, staged(w).count ], name
    end
  end

  test "missing or inconsistent staging is never committed" do
    cases = {
      "missing rows" => ->(w) { staged(w).delete_all },
      "missing fetch" => ->(w) { w.fetches.update_all(outcome: "mismatch") },
      "count differs from the validated total" => ->(w) { w.update_columns(fetched_count: 4) },
      "strings altered after hashing" => ->(w) { staged(w).limit(1).update_all(track_name: "Changed") },
      "play outside the window" => ->(w) { staged(w).limit(1).update_all(played_at: w.window_to) },
      "gap in positions" => ->(w) { staged(w).order(:played_at).limit(1).update_all(position: 7) }
    }
    cases.each_with_index do |(name, damage), i|
      w = window(@user, from: Time.utc(2015, 1 + i, 1), to: Time.utc(2015, 2 + i, 1))
      stage!(w, plays(3, from: w.window_from + 60))
      damage.(w)
      result = commit(w)
      assert_equal :needs_review, result.status, name
      assert_equal "needs_review", w.reload.state, name
      assert_equal 0, stored.count, name
    end
  end

  test "with history storage off, a commit and every bulk insert are refused" do
    stage!(@window, plays(2))
    Rails.configuration.x.history_import_enabled = nil
    assert_raises(HistoryImport::DisabledError) { commit }
    assert_equal "validated", @window.reload.state
    bulk = { user_id: @user.id, played_at: Time.utc(2014, 3, 2), seq: 0, name_variant_id: 1 }
    assert_raises(HistoryImport::DisabledError) { Scrobble.insert_all!([ bulk ]) }
    assert_raises(HistoryImport::DisabledError) { Scrobble.insert_all([ bulk ]) }
    assert_raises(HistoryImport::DisabledError) { Scrobble.upsert_all([ bulk ], unique_by: :index_scrobbles_identity) }
    assert_raises(HistoryImport::DisabledError) { Scrobble.insert(bulk) }
    assert_raises(HistoryImport::DisabledError) { NameVariant.insert_all([ { variant_hash: "x" * 32, artist_name: "a", track_name: "t" } ]) }
    assert_raises(HistoryImport::DisabledError) { ImportWindowRow.insert_all!([ { import_window_fetch_id: 1 } ]) }
    assert_equal 0, Scrobble.count
  end

  test "coverage counts only committed windows: complete, partial and missing" do
    april = window(@user, from: APRIL[0], to: APRIL[1])
    stage!(@window, plays(2))
    stage!(april, plays(1, from: APRIL[0] + 60))
    assert_equal :missing, ImportCoverage.status_for(@user, *MARCH), "validated but uncommitted is not coverage"

    commit
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH)
    assert_equal :partial, ImportCoverage.status_for(@user, MARCH[0], APRIL[1])
    assert_equal :missing, ImportCoverage.status_for(@user, *APRIL)
    assert ImportCoverage.complete?(@user, Time.utc(2014, 3, 5), Time.utc(2014, 3, 6))

    commit(april)
    assert_equal :complete, ImportCoverage.status_for(@user, MARCH[0], APRIL[1])
    assert_equal [ MARCH[0]...APRIL[1] ], ImportCoverage.ranges(@user)
  end

  test "committed coverage can't overlap" do
    stage!(@window, [])
    commit
    assert_db_rejects { window(@user, from: Time.utc(2014, 3, 15), to: Time.utc(2014, 4, 15)) }
  end

  test "accounts are isolated: another user's plays neither block nor join this commit" do
    other = history_user("other")
    scrobble(other, at: Time.utc(2014, 3, 10))
    stage!(@window, plays(2))
    assert_equal :committed, commit.status
    assert_equal 2, stored.count
    assert_equal 1, stored(other).count
    assert_equal :missing, ImportCoverage.status_for(other, *MARCH)
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH)
  end
end
