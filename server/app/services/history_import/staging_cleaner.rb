module HistoryImport
  # Removes staging rows nobody needs any more, so abandoned staging can't accumulate. Safe to run
  # at any time and repeatedly. Fetch records (the audit trail) are kept; only their rows go.
  #
  # Removed:
  # - staging of committed windows (the plays are in `scrobbles`);
  # - unfinished fetches of windows whose worker no longer holds a lease (a crashed worker);
  # - staging of windows validated more than STALE_AFTER ago that were never committed. Those
  #   windows go back to `pending` and are fetched again, since the snapshot is out of date anyway;
  # - staging still held by `pending` or `failed` windows (a commit that gave up), which are
  #   fetched again from scratch.
  #
  # Never touched: windows under a valid lease (a worker is busy with them), `committing` windows,
  # and `needs_review` windows, whose staging a reviewer may need.
  #
  # Each window is handled in its own short transaction holding the window's row lock, the same
  # lock workers take, so the cleaner and a worker never act on a window at the same time.
  class StagingCleaner
    STALE_AFTER = 7.days

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    # Returns the number of staging rows deleted, by reason.
    def call
      deleted = Hash.new(0)
      ImportWindow.committed.where(id: windows_with_staging).find_each { |window| deleted[:committed] += clean_window(window) }
      ImportWindow.where(id: windows_with_unfinished_fetches).find_each { |window| deleted[:abandoned] += abandon_fetches(window) }
      ImportWindow.where(state: "validated").where(validated_at: ...(now - STALE_AFTER)).find_each { |window| deleted[:stale] += reset_stale(window) }
      ImportWindow.where(state: %w[pending failed], id: windows_with_staging).find_each { |window| deleted[:refetch] += drop_refetch_staging(window) }
      deleted
    end

    # Deletes the staging of one committed window. Does nothing for any other state.
    def clean_window(window)
      locked(window) do |w|
        next 0 unless w.state == "committed"

        staging_for(w).delete_all
      end
    end

    private

    def now = @clock.call

    def locked(window)
      ImportWindow.transaction do
        w = ImportWindow.lock.find_by(id: window.id)
        w ? yield(w) : 0
      end
    end

    def idle?(window) = window.claim_token.nil? || window.lease_expires_at.nil? || window.lease_expires_at <= now

    def staging_for(window)
      ImportWindowRow.where(import_window_fetch_id: window.fetches.select(:id))
    end

    def windows_with_staging
      ImportWindowFetch.where(id: ImportWindowRow.select(:import_window_fetch_id)).select(:import_window_id)
    end

    def windows_with_unfinished_fetches
      ImportWindowFetch.where(outcome: "in_progress").select(:import_window_id)
    end

    def abandon_fetches(window)
      locked(window) do |w|
        next 0 unless idle?(w) && %w[pending failed fetching validating].include?(w.state)

        stale = w.fetches.where(outcome: "in_progress")
        count = ImportWindowRow.where(import_window_fetch_id: stale.select(:id)).delete_all
        stale.update_all(outcome: "failed", error_message: "abandoned: the worker stopped before finishing", finished_at: now, updated_at: now)
        count
      end
    end

    # Pending and failed windows are fetched again from scratch, so a snapshot they still hold
    # (from a commit that gave up) is never used.
    def drop_refetch_staging(window)
      locked(window) do |w|
        next 0 unless %w[pending failed].include?(w.state) && idle?(w)

        staging_for(w).where.not(import_window_fetch_id: w.fetches.where(outcome: "in_progress").select(:id)).delete_all
      end
    end

    def reset_stale(window)
      locked(window) do |w|
        next 0 unless w.state == "validated" && idle?(w) && w.validated_at < now - STALE_AFTER

        count = staging_for(w).delete_all
        w.update!(state: "pending", validated_at: nil, fetched_count: nil, expected_total: nil,
                  last_error_message: "validated snapshot expired before it was committed; fetching again")
        count
      end
    end
  end
end
