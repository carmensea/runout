require "test_helper"

class HistoryImport::StagingCleanerTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup { @user = history_user }

  def month(n) = window(@user, from: Time.utc(2014, n, 1), to: Time.utc(2014, n + 1, 1))

  def plays(w, count = 2) = Array.new(count) { |i| entry(w.window_from + ((i + 1) * 60), "Track #{i}") }

  def staged(w) = ImportWindowRow.where(import_window_fetch_id: w.fetches.select(:id))

  def clean(now: Time.current) = HistoryImport::StagingCleaner.new(clock: -> { now }).call

  def lease!(w, expires:) = w.update_columns(claim_token: SecureRandom.uuid, lease_expires_at: expires)

  test "staging of a committed window is removed; fetch records are kept" do
    w = month(3)
    stage!(w, plays(w))
    w.update_columns(state: "committed", committed_at: Time.current, committed_count: 2) # as if the commit's cleanup step was lost
    assert_equal({ committed: 2 }, clean.to_h)
    assert_equal 0, staged(w).count
    assert_equal 1, w.fetches.count
  end

  test "unfinished fetches are discarded only once no worker holds the window" do
    active = month(3)
    crashed = month(4)
    [ active, crashed ].each do |w|
      f = fetch(w, outcome: "in_progress")
      ImportWindowRow.insert_all!(HistoryImport::Snapshot.new(entries: plays(w), reported_total: 2, total_pages: 1)
                                    .staging_rows.map { |r| r.merge(import_window_fetch_id: f.id) })
      w.update_columns(state: "fetching")
    end
    lease!(active, expires: 10.minutes.from_now)
    lease!(crashed, expires: 1.minute.ago)

    assert_equal({ abandoned: 2 }, clean.to_h)
    assert_equal 2, staged(active).count, "a busy worker's staging is never touched"
    assert_equal "in_progress", active.fetches.sole.outcome
    assert_equal 0, staged(crashed).count
    assert_equal "failed", crashed.fetches.sole.outcome
  end

  test "a validated snapshot left uncommitted for too long is discarded and the window refetched" do
    old = month(3)
    fresh = month(4)
    stage!(old, plays(old), at: 8.days.ago)
    stage!(fresh, plays(fresh), at: 1.day.ago)

    assert_equal({ stale: 2 }, clean.to_h)
    assert_equal 0, staged(old).count
    assert_equal [ "pending", nil, nil ], [ old.reload.state, old.validated_at, old.fetched_count ]
    assert_equal 2, staged(fresh).count
    assert_equal "validated", fresh.reload.state
  end

  test "windows under review, committing, or leased are never touched, however old" do
    review = month(3)
    committing = month(4)
    stage!(review, plays(review), at: 30.days.ago)
    stage!(committing, plays(committing), at: 30.days.ago)
    review.update_columns(state: "needs_review")
    committing.update_columns(state: "committing")
    lease!(committing, expires: 10.minutes.from_now)

    assert_empty clean.to_h
    assert_equal [ 2, 2 ], [ staged(review).count, staged(committing).count ]
    assert_equal [ "needs_review", "committing" ], [ review.reload.state, committing.reload.state ]
  end

  test "cleaning is idempotent" do
    w = month(3)
    stage!(w, plays(w), at: 8.days.ago)
    clean
    assert_empty clean.to_h
  end

  test "clean_window ignores windows that aren't committed" do
    w = month(3)
    stage!(w, plays(w))
    assert_equal 0, HistoryImport::StagingCleaner.new.clean_window(w)
    assert_equal 2, staged(w).count
  end
end
