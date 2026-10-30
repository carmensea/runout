require "test_helper"

class ReconciliationTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup do
    @user = history_user
    @original = variant(track: "Orignal Title")
    @scrobble = scrobble(@user, at: Time.utc(2014, 3, 15, 20), variant: @original)
    w = window(@user, from: Time.utc(2014, 3, 1), to: Time.utc(2014, 4, 1))
    @fetch1 = fetch(w, attempt: 1)
    @fetch2 = fetch(w, attempt: 2)
  end

  def correction(state:, to: variant(track: "Original Title"), **attrs)
    ScrobbleCorrection.create!(user: @user, scrobble: @scrobble, from_variant: @original, to_variant: to, state: state,
                               reason: "test", import_window_fetch: @fetch1, **attrs)
  end

  def removal(state: "observed", **attrs)
    ScrobbleRemoval.create!(user: @user, scrobble: @scrobble, first_missing_fetch: @fetch1, state: state, **attrs)
  end

  test "an uncertain correction is flagged and leaves the original strings in place" do
    correction(state: "pending_review", reason: "several plays in the same second")
    assert_equal @original, @scrobble.reload.name_variant
    assert_equal 1, @user.scrobble_corrections.pending.count
  end

  test "a scrobble has at most one open correction, but keeps its full correction history" do
    correction(state: "pending_review")
    assert_db_rejects(ActiveRecord::RecordNotUnique) { correction(state: "pending_review", to: variant(track: "Third")) }
    correction(state: "dismissed", to: variant(track: "Old idea"), decided_at: Time.current, decided_by: @user)
    correction(state: "applied", to: variant(track: "Older"), decided_at: Time.current)
    assert_equal 3, @scrobble.corrections.count
  end

  test "decided corrections record when, and a correction must change something" do
    assert_db_rejects { correction(state: "applied") }
    assert_db_rejects { correction(state: "pending_review", to: @original) }
  end

  test "a removal needs two agreeing fetches before it can be reviewed" do
    r = removal
    assert_db_rejects { r.update_columns(state: "pending_review") }
    r.update!(state: "pending_review", confirming_fetch: @fetch2)
    assert_nil @scrobble.reload.removed_at, "pending review never removes anything"
  end

  test "approving or dismissing a removal records the decision" do
    r = removal(state: "pending_review", confirming_fetch: @fetch2)
    assert_db_rejects { r.update_columns(state: "approved") }
    r.update!(state: "approved", decided_at: Time.current, decided_by: @user, decision_note: "deleted on Last.fm")
    assert_equal @user, r.reload.decided_by
  end

  test "a scrobble has at most one open removal proposal; closed ones stay for audit" do
    removal
    assert_db_rejects(ActiveRecord::RecordNotUnique) { removal }
    ScrobbleRemoval.unresolved.sole.update!(state: "restored")
    removal
    assert_equal 2, @scrobble.removals.count
  end

  test "deleting the account removes all history and reconciliation records, but not shared catalogue strings" do
    correction(state: "pending_review")
    removal
    @user.destroy!
    assert_equal 0, Scrobble.count
    assert_equal 0, ImportWindow.count
    assert_equal 0, ImportWindowFetch.count
    assert_equal 0, ScrobbleCorrection.count
    assert_equal 0, ScrobbleRemoval.count
    assert_operator NameVariant.count, :>, 0, "shared variants are cleaned up by a later job, not by cascade"
  end
end
