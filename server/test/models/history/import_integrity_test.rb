require "test_helper"

class ImportIntegrityTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup do
    @user = history_user
    @march = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ]
    @april = [ Time.utc(2014, 4, 1), Time.utc(2014, 5, 1) ]
  end

  test "windows have explicit, ordered bounds" do
    assert_not ImportWindow.new(user: @user, window_from: @march[1], window_to: @march[0]).valid?
    assert_db_rejects do
      ImportWindow.insert_all!([ { user_id: @user.id, window_from: @march[1], window_to: @march[0], state: "pending",
                                   created_at: Time.current, updated_at: Time.current } ])
    end
  end

  test "adjacent monthly windows are allowed; overlapping live windows are not" do
    window(@user, from: @march[0], to: @march[1])
    window(@user, from: @april[0], to: @april[1])
    assert_db_rejects { window(@user, from: Time.utc(2014, 3, 20), to: Time.utc(2014, 4, 10)) }
    assert window(history_user("other"), from: @march[0], to: @march[1]), "other users' windows are independent"
  end

  test "a split window stops counting, so its halves may cover the same range" do
    parent = window(@user, from: @march[0], to: @march[1])
    parent.update!(state: "split")
    mid = Time.utc(2014, 3, 16)
    window(@user, from: @march[0], to: mid, parent_window: parent)
    window(@user, from: mid, to: @march[1], parent_window: parent)
    assert_equal 2, @user.import_windows.live.count
  end

  test "the same window cannot be planned twice" do
    window(@user, from: @march[0], to: @march[1])
    # Rejected by the no-overlap constraint (or the unique index): either way it can't exist twice.
    assert_db_rejects { window(@user, from: @march[0], to: @march[1]) }
  end

  test "states are constrained, and committed or validated windows must say when" do
    w = window(@user, from: @march[0], to: @march[1])
    assert_db_rejects { w.update_columns(state: "done") }
    assert_db_rejects { w.update_columns(state: "committed") }
    assert_db_rejects { w.update_columns(state: "validated") }
    w.update!(state: "validated", validated_at: Time.current)
    w.update!(state: "committed", committed_at: Time.current, committed_count: 0)
    assert_equal "committed", w.reload.state
  end

  test "a lease lets exactly one worker hold a window, and expires after a crash" do
    w = window(@user, from: @march[0], to: @march[1])
    a = SecureRandom.uuid
    b = SecureRandom.uuid
    now = Time.current
    assert w.claim!(a, now: now)
    assert_not w.claim!(b, now: now + 5.minutes), "a second worker can't take a live lease"
    assert w.claim!(b, now: now + ImportWindow::LEASE + 1.second), "an expired lease can be taken over"

    w.release!(a)
    assert_equal b, w.reload.claim_token, "only the holder can release"
    w.release!(b)
    assert_nil w.reload.claim_token
  end

  test "claim tokens must be UUIDs, so a bad token can't silently leave a window unclaimed" do
    w = window(@user, from: @march[0], to: @march[1])
    assert_raises(ArgumentError) { w.claim!("token-a") }
    assert_raises(ArgumentError) { w.release!("token-a") }
    assert_nil w.reload.claim_token
  end

  test "optimistic locking stops two stale writers from both changing a window" do
    w = window(@user, from: @march[0], to: @march[1])
    stale = ImportWindow.find(w.id)
    w.update!(state: "fetching")
    assert_raises(ActiveRecord::StaleObjectError) { stale.update!(state: "failed") }
  end

  test "fetch attempts are numbered once per window and keep their error details" do
    w = window(@user, from: @march[0], to: @march[1])
    f = fetch(w, attempt: 1, outcome: "failed", http_status: 502, lastfm_error: 8, error_page: 3, error_message: "Operation failed")
    assert_equal [ 502, 8, 3 ], [ f.http_status, f.lastfm_error, f.error_page ]
    assert_db_rejects(ActiveRecord::RecordNotUnique) { fetch(w, attempt: 1) }
    assert_db_rejects { f.update_columns(outcome: "ok") }
  end

  test "a snapshot keeps identical plays in one second apart by occurrence" do
    f = fetch(window(@user, from: @march[0], to: @march[1]))
    at = Time.utc(2014, 3, 15, 20)
    hash = NameVariant.hash_for(artist_name: "A", track_name: "T", album_name: "")
    row = ->(position, occurrence) { f.rows.create!(played_at: at, position: position, occurrence: occurrence, variant_hash: hash, artist_name: "A", track_name: "T") }
    row.(0, 0)
    row.(1, 1)
    assert_equal 2, f.rows.count
    assert_db_rejects(ActiveRecord::RecordNotUnique) { row.(2, 1) }
    assert_db_rejects(ActiveRecord::RecordNotUnique) { row.(1, 2) }
  end

  test "discarding a fetch discards its staged snapshot" do
    f = fetch(window(@user, from: @march[0], to: @march[1]))
    f.rows.create!(played_at: @march[0], position: 0, occurrence: 0, variant_hash: NameVariant.hash_for({}), artist_name: "A", track_name: "T")
    f.destroy!
    assert_equal 0, ImportWindowRow.count
  end

  test "coverage reports only committed periods, merging adjacent windows" do
    committed = ->(range) { window(@user, from: range[0], to: range[1], state: "committed", validated_at: Time.current, committed_at: Time.current, committed_count: 0) }
    committed.(@march)
    committed.(@april)
    window(@user, from: Time.utc(2014, 5, 1), to: Time.utc(2014, 6, 1), state: "failed")

    assert_equal [ @march[0]...@april[1] ], ImportCoverage.ranges(@user)
    assert ImportCoverage.complete?(@user, Time.utc(2014, 3, 10), Time.utc(2014, 4, 20))
    assert_not ImportCoverage.complete?(@user, Time.utc(2014, 4, 20), Time.utc(2014, 5, 10)), "May failed, so not complete"
  end
end
