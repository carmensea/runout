require "test_helper"

# Stage 2.4b: reconciling committed months with later validated snapshots. Synthetic data only.
class HistoryImport::ReconciliationTest < ActiveSupport::TestCase
  include HistoryHelpers

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze
  T = Time.utc(2014, 3, 15, 20) # a second with several plays
  U = Time.utc(2014, 3, 20, 9)  # an unrelated second

  setup do
    @user = history_user
    @reviewer = @user
    @window = window(@user, from: MARCH[0], to: MARCH[1])
  end

  def commit(window = @window) = HistoryImport::WindowCommitter.new(window: window).call

  # A validated snapshot of the month, committed (the first time) or reconciled (afterwards).
  def check!(entries, window = @window)
    fetch = stage!(window.reload, entries)
    @staged_rows = fetch.rows.map { |row| row.attributes.except("id") }
    result = commit(window)
    assert_equal :committed, result.status, result.detail
    window.reload
  end

  # Commits the last validated snapshot again, as a crash recovery replaying it would: the same
  # fetch, with its staged rows restored (they are cleaned up after a commit).
  def replay!(window = @window)
    ImportWindowRow.insert_all!(@staged_rows) if @staged_rows.any?
    window.reload.update!(state: "validated", validated_at: Time.current, fetched_count: @staged_rows.size, expected_total: @staged_rows.size)
    assert_equal :committed, commit(window).status
  end

  def stored(user = @user) = Scrobble.where(user: user).order(:played_at, :seq)

  def snapshot_of(scope = stored.present)
    scope.includes(:name_variant).map { |s| [ s.played_at, s.seq, s.name_variant.track_name, s.removed_at.present? ] }
  end

  def base = [ entry(T, "A"), entry(T, "B"), entry(T, "C"), entry(U, "U") ]

  def status = HistoryImport::SyncStatus.for(@user).sole

  def removal_for(track) = ScrobbleRemoval.joins(scrobble: :name_variant).where(name_variants: { track_name: track }).order(:id).last

  test "an identical snapshot changes nothing and marks the month synchronized" do
    check!(base)
    before = snapshot_of
    ids = stored.pluck(:id)
    window = check!(base)
    assert_equal before, snapshot_of
    assert_equal ids, stored.pluck(:id)
    assert_equal({ "matched" => 4, "added" => 0 }, window.last_check_summary)
    assert_equal [ 0, 0, 0 ], [ ReconciliationDispute.count, ScrobbleRemoval.count, ScrobbleCorrection.count ]
    assert_equal :synchronized, status.status
  end

  test "a different order within a second is not a change" do
    check!(base)
    before = snapshot_of
    check!([ entry(T, "C"), entry(U, "U"), entry(T, "A"), entry(T, "B") ])
    assert_equal before, snapshot_of
    assert ReconciliationDispute.none?
  end

  test "identical plays in one second: kept, extra ones added after the last slot, missing ones suspected" do
    same = Array.new(3) { entry(T, "Same") }
    check!(same)
    check!(same + [ entry(T, "Same") ])
    assert_equal [ 0, 1, 2, 3 ], stored.pluck(:seq)
    check!(same)
    assert_equal 4, stored.present.count, "nothing is removed automatically"
    removal = ScrobbleRemoval.sole
    assert_equal [ "observed", 3 ], [ removal.state, removal.scrobble.seq ]
  end

  test "unambiguous new plays are added without touching existing slots" do
    check!(base)
    ids = stored.pluck(:id, :seq)
    check!(base + [ entry(T, "D"), entry(Time.utc(2014, 3, 2), "New second") ])
    assert_equal ids, stored.where(id: ids.map(&:first)).pluck(:id, :seq)
    assert_equal [ 3 ], stored.joins(:name_variant).where(name_variants: { track_name: "D" }).pluck(:seq)
    assert_equal 6, @window.reload.committed_count
    assert_equal 2, @window.last_check_summary["added"]
  end

  test "a single renamed play goes to review; nothing in that second changes" do
    check!([ entry(T, "Song"), entry(U, "U") ])
    before = snapshot_of
    check!([ entry(T, "Song (Remastered)"), entry(U, "U") ])
    assert_equal before, snapshot_of
    dispute = ReconciliationDispute.sole
    assert_equal [ "open", T ], [ dispute.state, dispute.played_at ]
    assert_equal [ "Song" ], dispute.stored_scrobbles.map { |s| s.name_variant.track_name }
    assert_equal [ "Song (Remastered)" ], dispute.proposed_variants.map(&:track_name), "the fetched strings are kept as evidence"
    assert ScrobbleRemoval.none?, "no removal bookkeeping in a disputed second"
    assert_equal :differences, status.status
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH), "a disagreement never takes coverage away"
  end

  test "several changes in one second become one dispute; exact matches are left alone" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "D"), entry(T, "E"), entry(U, "U") ])
    dispute = ReconciliationDispute.sole
    assert_equal %w[B C], dispute.stored_scrobbles.map { |s| s.name_variant.track_name }
    assert_equal %w[D E], dispute.proposed_variants.map(&:track_name).sort
    assert_equal 4, stored.count
  end

  test "a missing play needs two independent validated checks before review, never removed automatically" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "B"), entry(U, "U") ])
    assert_equal "observed", removal_for("C").state
    assert_equal :suspected, status.status

    replay!
    assert_equal "observed", removal_for("C").reload.state, "replaying the same snapshot is not a new observation"

    check!([ entry(T, "A"), entry(T, "B"), entry(U, "U") ])
    removal = removal_for("C").reload
    assert_equal "pending_review", removal.state
    assert_operator removal.confirming_fetch.attempt, :>, removal.first_missing_fetch.attempt
    assert_nil removal.scrobble.removed_at
    assert_equal :differences, status.status
    assert_equal 1, ScrobbleRemoval.count
  end

  test "the two reads inside one validation count as one observation" do
    plays = %w[A B C].map { |t| FakeRecentTracks::Play.new(played_at: T, artist: "Artist", track: t, album: "", artist_mbid: "", track_mbid: "", album_mbid: "") }
    fake = FakeRecentTracks.new(plays).install(self)
    validate_and_commit = lambda do
      @window.reload.update!(state: "pending") unless @window.state == "pending"
      result = HistoryImport::WindowValidator.new(window: @window, client: stub_client(**Lastfm::Client::BACKGROUND_OPTIONS), username: "listener").call
      assert_equal :validated, result.status
      assert_equal :committed, commit.status
    end
    validate_and_commit.()
    fake.remove_if { |p| p.track == "C" }
    validate_and_commit.()
    latest = @window.fetches.where(outcome: "validated").order(:attempt).last(2)
    assert_equal [ 3, 4 ], latest.map(&:attempt), "two complete reads agreed in this validation"
    assert_equal "observed", removal_for("C").state, "still only one observation"
    validate_and_commit.()
    assert_equal "pending_review", removal_for("C").reload.state, "the next validation is independent"
  end

  test "a play that reappears closes its removal proposal" do
    check!(base)
    2.times { check!([ entry(T, "A"), entry(T, "B"), entry(U, "U") ]) }
    assert_equal "pending_review", removal_for("C").state
    check!(base)
    assert_equal "restored", removal_for("C").reload.state
    assert_equal :synchronized, status.status
    assert ReviewDecision.exists?(subject_type: "ScrobbleRemoval", action: "seen_again")
  end

  test "approving removes the play softly; dismissing keeps it and isn't reopened by unchanged evidence" do
    check!(base)
    missing = [ entry(T, "A"), entry(U, "U") ]
    2.times { check!(missing) }
    approve, dismiss = %w[B C].map { |t| removal_for(t) }
    assert_raises(HistoryImport::Review::Invalid, "observed is not yet reviewable") do
      HistoryImport::Review.approve_removal!(ScrobbleRemoval.create!(user: @user, scrobble: stored.find_by!(seq: 0, played_at: U),
                                                                     first_missing_fetch: @window.fetches.first), by: @reviewer)
    end

    assert_equal :approved, HistoryImport::Review.approve_removal!(approve, by: @reviewer, note: "deleted on Last.fm")
    assert_equal :already, HistoryImport::Review.approve_removal!(approve, by: @reviewer), "retrying is safe"
    assert approve.scrobble.reload.removed_at
    assert_equal 3, @window.reload.committed_count
    assert_equal :dismissed, HistoryImport::Review.dismiss_removal!(dismiss, by: @reviewer)

    removals = ScrobbleRemoval.count
    3.times { check!(missing) }
    assert_equal %w[approved dismissed], [ approve.reload.state, dismiss.reload.state ]
    assert_equal removals, ScrobbleRemoval.count, "unchanged evidence opens nothing new"
    assert_equal :synchronized, status.status

    # New evidence: the dismissed play is seen again, then goes missing again.
    check!(missing + [ entry(T, "C") ])
    assert_equal "restored", dismiss.reload.state
    check!(missing)
    assert_equal "observed", removal_for("C").state
    assert_equal removals + 1, ScrobbleRemoval.count
    assert ReviewDecision.exists?(subject_type: "ScrobbleRemoval", subject_id: dismiss.id, action: "seen_after_dismissal")
  end

  test "an approved removal whose play reappears is reviewed again: restore or keep removed" do
    check!(base)
    2.times { check!([ entry(T, "A"), entry(T, "B"), entry(U, "U") ]) }
    removal = removal_for("C")
    HistoryImport::Review.approve_removal!(removal, by: @reviewer)
    check!(base)
    assert_equal "reappeared", removal.reload.state
    assert_equal 4, stored.count, "matched against the removed play: no duplicate inserted"
    assert_equal :differences, status.status
    assert_equal :restored, HistoryImport::Review.restore_reappeared!(removal, by: @reviewer)
    assert_nil removal.scrobble.reload.removed_at
    assert_equal 4, @window.reload.committed_count
  end

  test "resolving a dispute applies only the reviewer's pairs; leftovers follow the one-sided rules" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "B (live)"), entry(T, "Extra"), entry(U, "U") ])
    dispute = ReconciliationDispute.sole
    b = dispute.stored_scrobbles.find { |s| s.name_variant.track_name == "B" }
    live_index = dispute.proposed_variants.index { |v| v.track_name == "B (live)" }
    assert_raises(HistoryImport::Review::Invalid) { HistoryImport::Review.resolve_dispute!(dispute, by: @reviewer, pairs: [ [ b.id, 9 ] ]) }

    assert_equal :resolved, HistoryImport::Review.resolve_dispute!(dispute, by: @reviewer, pairs: [ [ b.id, live_index ] ])
    assert_equal :already, HistoryImport::Review.resolve_dispute!(dispute, by: @reviewer, pairs: [ [ b.id, live_index ] ])
    assert_equal "B (live)", b.reload.name_variant.track_name
    correction = ScrobbleCorrection.sole
    assert_equal [ "applied", "B", "B (live)" ], [ correction.state, correction.from_variant.track_name, correction.to_variant.track_name ]
    assert_equal [ 0, 1, 2, 3 ], stored.where(played_at: T).pluck(:seq), "Extra added after the last slot"
    assert_equal "observed", removal_for("C").state, "the unpaired stored play is only suspected missing"
    assert_nil removal_for("C").scrobble.removed_at
    assert ReviewDecision.exists?(subject_type: "ReconciliationDispute", subject_id: dispute.id, action: "resolved")

    check!([ entry(T, "A"), entry(T, "B (live)"), entry(T, "Extra"), entry(U, "U") ])
    assert_equal 0, ReconciliationDispute.open.count, "the next check agrees"
  end

  test "a dismissed dispute stays closed for the same evidence and reopens for new evidence" do
    check!(base)
    renamed = [ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U") ]
    check!(renamed)
    HistoryImport::Review.dismiss_dispute!(ReconciliationDispute.sole, by: @reviewer)
    2.times { check!(renamed) }
    assert_equal 1, ReconciliationDispute.count
    check!([ entry(T, "A"), entry(T, "B"), entry(T, "C3"), entry(U, "U") ])
    assert_equal %w[dismissed open], ReconciliationDispute.order(:id).pluck(:state)
  end

  test "an open dispute is superseded when the evidence changes, and touched when it doesn't" do
    check!(base)
    renamed = [ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U") ]
    check!(renamed)
    first = ReconciliationDispute.sole
    window = check!(renamed)
    assert_equal window.last_check_fetch_id, first.reload.last_seen_fetch_id
    assert_equal 1, ReconciliationDispute.count, "no duplicate review records"
    check!(base) # Last.fm went back to what is stored
    assert_equal "superseded", first.reload.state
    assert_equal :synchronized, status.status
  end

  test "replaying a reconciled snapshot duplicates nothing" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(T, "D"), entry(Time.utc(2014, 3, 3), "New"), entry(U, "U") ])
    before = [ snapshot_of(stored), ReconciliationDispute.pluck(:id, :state), ScrobbleRemoval.count, ReviewDecision.count ]
    replay!
    assert_equal before, [ snapshot_of(stored), ReconciliationDispute.pluck(:id, :state), ScrobbleRemoval.count, ReviewDecision.count ]
  end

  test "a disputed second doesn't block safe additions elsewhere in the month" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U"), entry(U, "U again"), entry(Time.utc(2014, 3, 4), "New") ])
    assert_equal 1, ReconciliationDispute.open.count
    assert_equal %w[A B C], stored.where(played_at: T).map { |s| s.name_variant.track_name }
    assert_equal 6, stored.count, "two additions applied in the same transaction"
  end

  test "a failure halfway through applies nothing, and the check can be retried" do
    check!(base)
    stage!(@window.reload, [ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U"), entry(Time.utc(2014, 3, 4), "New"),
                             entry(Time.utc(2014, 3, 5), "Gone") ].first(5))
    Scrobble.define_singleton_method(:insert_all!) { |*| raise ActiveRecord::ConnectionFailed, "simulated" }
    begin
      assert_equal :failed, commit.status
    ensure
      Scrobble.singleton_class.remove_method(:insert_all!)
    end
    assert_equal [ 4, 0, 0, 0 ], [ stored.count, ReconciliationDispute.count, ScrobbleRemoval.count, ReviewDecision.count ]
    assert_equal "validated", @window.reload.state
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH), "coverage kept while the check is retried"
    assert_equal :committed, commit.status
    assert_equal [ 5, 1 ], [ stored.count, ReconciliationDispute.count ]
  end

  test "with storage off, reconciliation, rechecks and review decisions are refused" do
    check!(base)
    2.times { check!([ entry(T, "A"), entry(T, "B"), entry(U, "U") ]) }
    stage!(@window.reload, base)
    Rails.configuration.x.history_import_enabled = nil
    assert_raises(HistoryImport::DisabledError) { commit }
    assert_raises(HistoryImport::DisabledError) { HistoryImport::Review.approve_removal!(removal_for("C"), by: @reviewer) }
    assert_raises(HistoryImport::DisabledError) { HistoryImport::Recheck.request!(@user) }
    assert_equal "pending_review", removal_for("C").state
  end

  test "accounts are isolated: another user's plays and reviews at the same seconds are untouched" do
    other = history_user("other")
    other_window = window(other, from: MARCH[0], to: MARCH[1])
    check!(base)
    check!(base, other_window)
    check!([ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U") ])
    assert_equal 1, ReconciliationDispute.where(user: @user).count
    assert_equal 0, ReconciliationDispute.where(user: other).count
    assert_equal 4, stored(other).count
    assert_equal :synchronized, HistoryImport::SyncStatus.for(other).sole.status
  end

  test "coverage, synchronisation and review status stay separate" do
    check!(base)
    assert_equal :synchronized, status.status
    travel 31.days
    assert_equal :stale, status.status, "not checked recently"
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH)
    HistoryImport::Recheck.request!(@user)
    assert_equal :checking, status.status
    assert_equal :complete, ImportCoverage.status_for(@user, *MARCH), "a month being checked keeps its coverage"
    assert HistoryImport::Progress.for(@user).windows[:committed] == 1
  end

  test "the database rejects a second open dispute for the same second" do
    check!(base)
    check!([ entry(T, "A"), entry(T, "B"), entry(T, "C2"), entry(U, "U") ])
    d = ReconciliationDispute.sole
    assert_db_rejects(ActiveRecord::RecordNotUnique) do
      ReconciliationDispute.create!(d.attributes.except("id", "created_at", "updated_at"))
    end
  end
end
