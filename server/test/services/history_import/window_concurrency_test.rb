require "test_helper"

# Real concurrency: threads hold separate database connections, like separate worker processes.
# Committed data is needed, so no transactional wrapper; the test cleans up its own rows.
class HistoryImport::WindowConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @flag = Rails.configuration.x.history_import_enabled
    Rails.configuration.x.history_import_enabled = "true"
    @user = User.create!(display_name: "concurrency-#{SecureRandom.hex(4)}")
    @window = ImportWindow.create!(user: @user, window_from: Time.utc(2014, 3, 1), window_to: Time.utc(2014, 4, 1))
  end

  teardown do
    @user.destroy! # cascades to windows
    Rails.configuration.x.history_import_enabled = @flag
  end

  test "compacting staging never truncates under a worker that is staging rows" do
    fetch = @window.fetches.create!(attempt: 1, started_at: Time.current)
    entries = Array.new(3) { |i| HistoryImport::Snapshot::Entry.new(played_at: Time.utc(2014, 3, 2) + i, artist: "A", artist_mbid: "", track: "T#{i}", track_mbid: "", album: "", album_mbid: "") }
    rows = HistoryImport::Snapshot.new(entries: entries, reported_total: 3, total_pages: 1).staging_rows.map { |r| r.merge(import_window_fetch_id: fetch.id) }
    staged = Queue.new
    finish = Queue.new
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ImportWindowRow.transaction do
          ImportWindowRow.insert_all!(rows) # not committed yet: invisible to others
          staged << true
          finish.pop
        end
      end
    end
    staged.pop
    started = Time.now
    assert_equal 0, HistoryImport::StagingCleaner.new.compact!(above: 0), "waits for the worker's lock, then gives up"
    assert_operator Time.now - started, :>=, 1.5
    finish << true
    worker.join
    assert_equal 3, ImportWindowRow.where(import_window_fetch_id: fetch.id).count, "the worker's rows survived"
  ensure
    finish&.push(true)
    worker&.join
    ImportWindowRow.where(import_window_fetch_id: fetch&.id).delete_all
  end

  test "exactly one of several simultaneous workers claims a window" do
    start = Queue.new
    results = Queue.new
    threads = Array.new(6) do
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          token = SecureRandom.uuid
          results << [ token, ImportWindow.find(@window.id).claim_for_validation!(token) ]
        end
      end
    end
    6.times { start << :go }
    threads.each(&:join)
    outcomes = Array.new(6) { results.pop }
    winners = outcomes.select(&:last)
    assert_equal 1, winners.size
    assert_equal winners.sole.first, @window.reload.claim_token
    assert_equal 1, @window.attempts
  end

  test "of several workers committing one window at once, exactly one commits" do
    fetch = @window.fetches.create!(attempt: 1, started_at: Time.current, outcome: "validated", expected_total: 50, row_count: 50)
    entries = Array.new(50) do |i|
      HistoryImport::Snapshot::Entry.new(played_at: Time.utc(2014, 3, 2) + (i / 2), artist: "Artist", artist_mbid: "",
                                         track: "Track #{i % 3}", track_mbid: "", album: "", album_mbid: "")
    end
    rows = HistoryImport::Snapshot.new(entries: entries, reported_total: 50, total_pages: 1).staging_rows
    ImportWindowRow.insert_all!(rows.map { |r| r.merge(import_window_fetch_id: fetch.id) })
    @window.update!(state: "validated", validated_at: Time.current, expected_total: 50, fetched_count: 50)

    start = Queue.new
    results = Queue.new
    threads = Array.new(6) do
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          results << HistoryImport::WindowCommitter.new(window: ImportWindow.find(@window.id)).call.status
        end
      end
    end
    6.times { start << :go }
    threads.each(&:join)
    statuses = Array.new(6) { results.pop }
    assert_equal [ :committed ], statuses.uniq - [ :not_claimed ]
    assert_equal 1, statuses.count(:committed)
    assert_equal 50, Scrobble.where(user: @user).count
    assert_equal [ "committed", 50 ], [ @window.reload.state, @window.committed_count ]
  ensure
    variant_ids = Scrobble.where(user: @user).distinct.pluck(:name_variant_id)
    Scrobble.where(user: @user).delete_all
    NameVariant.where(id: variant_ids).delete_all
  end
end
