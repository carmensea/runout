require "test_helper"

# Stage 2.8 §15.7: status costs a fixed number of queries, however long the history. Synthetic
# histories of 1 and 20 years (one committed window per month, plays in each, open review items
# spread through them), measured with Active Record's SQL notifications.
class HistoryImport::StatusQueriesTest < ActiveSupport::TestCase
  include HistoryHelpers

  PLAYS_PER_MONTH = 30

  # A committed month per window from `years` ago, with plays, a dispute every 12 months and a
  # pending removal every 7.
  def history(years)
    user = history_user("q#{years}")
    identity = Identity.create!(user: user, provider: Identity::LASTFM, uid: "q#{years}", username: "q#{years}",
                                registered_at: Time.utc(2000, 1, 1), credentials: { "session_key" => "sk" })
    LastfmConnection.create!(user: user, identity: identity, history_state: "imported", last_synced_at: Time.current)
    ImportRun.create!(user: user, kind: "full", state: "completed", started_at: 1.day.ago, finished_at: 1.day.ago)
    v = variant
    start = Time.utc(2026, 10, 1) - years.years
    months = HistoryImport::MonthlyWindows.ranges(from: start, cutoff: Time.utc(2026, 10, 1))
    months.each_with_index do |range, i|
      w = window(user, from: range.begin, to: range.end, state: "committed", validated_at: Time.current, committed_at: Time.current,
                       committed_count: PLAYS_PER_MONTH, last_verified_at: Time.current, present_count: PLAYS_PER_MONTH)
      Scrobble.insert_all!(Array.new(PLAYS_PER_MONTH) { |n| { user_id: user.id, played_at: range.begin + (n * 3600), seq: 0, name_variant_id: v.id } })
      f = fetch(w, outcome: "validated")
      if (i % 12).zero?
        s = Scrobble.find_by!(user: user, played_at: range.begin)
        ReconciliationDispute.create!(user: user, import_window: w, played_at: s.played_at, stored_scrobble_ids: [ s.id ],
                                      proposed_variant_ids: [ variant(track: "Other #{i}").id ], evidence_key: SecureRandom.hex,
                                      first_seen_fetch: f, last_seen_fetch: f)
      end
      if (i % 7).zero?
        s = Scrobble.find_by!(user: user, played_at: range.begin + 3600)
        ScrobbleRemoval.create!(user: user, scrobble: s, first_missing_fetch: f, confirming_fetch: f, state: "pending_review")
      end
    end
    [ user, months.size ]
  end

  def queries
    count = 0
    counter = lambda do |*, payload|
      count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] || payload[:sql].match?(/\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i)
    end
    # Uncached: every query is counted, as in a request that runs it first.
    ActiveRecord::Base.uncached { ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield } }
    count
  end

  def measure(user)
    user = User.find(user.id)
    {
      health: queries { HistoryImport::SyncHealth.for(user) },
      version: queries { HistoryImport::SyncHealth.version(user) },
      connection: queries { ConnectionState.for(User.find(user.id)) } - 3, # minus loading the user, identity and connection
      import: queries { HistoryImport::ImportStatus.for(user) },
      reviews: queries { HistoryImport::ReviewQueue.for(user) },
      attention: queries { HistoryImport::Attention.for(user) }
    }
  end

  test "status, connection, import and review queries don't grow with the history: 1 year and 20 years cost the same" do
    short, short_months = history(1)
    long, long_months = history(20)
    assert_equal [ 12, 240 ], [ short_months, long_months ]
    assert_equal 240 * PLAYS_PER_MONTH, Scrobble.where(user: long).count

    small = measure(short)
    large = measure(long)
    puts "QUERIES #{large.inspect}" if ENV["SHOW_QUERIES"]
    assert_equal small, large, "the same number of queries for 12 and 240 months"
    assert_operator large[:health], :<=, 8, "GET /api/sync, as planned (§15.7)"
    assert_operator large[:version], :<=, 1, "the ETag check"
    assert_operator large[:attention], :<=, 4
  end

  test "the 20-year summary is right, not only cheap" do
    user, months = history(20)
    h = HistoryImport::SyncHealth.for(user)
    assert_equal 52, h[:periods][:differences], "months with a dispute (20) or a removal (35); 3 have both"
    assert_equal 20, h[:reviews][:disputes]
    assert_equal 35, h[:reviews][:pendingRemovals]
    assert_equal 55, h[:attention][:total]
    assert_equal 55, HistoryImport::Attention.for(user)[:total]
    assert_equal [ { from: Time.utc(2006, 10, 1).iso8601, to: Time.utc(2026, 10, 1).iso8601 } ], h[:coverage]
    assert_empty h[:missingPeriods]
    assert_equal months - h[:periods][:differences], h[:periods][:synchronized]
  end
end
