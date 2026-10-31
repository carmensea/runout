module HistoryImport
  # Fetches and validates one window (docs/milestone-2-plan.md §4.3). Doesn't commit anything to
  # `scrobbles`; that's Stage 2.4.
  #
  # Validated means two consecutive complete snapshots have the same plays: the same multiset of
  # seconds and exact strings, with the same occurrence counts, in any order (Snapshot#equivalent?).
  # MusicBrainz IDs aren't part of a play: where the two reads disagree on one, the play is staged
  # without it and the candidates are recorded (MbidDispute). Up to MAX_SNAPSHOTS snapshots are
  # taken; a window that never settles goes to `needs_review`, never to `validated`.
  #
  # Transaction safety:
  # - Network requests happen only outside transactions.
  # - Every database write is a short transaction under the worker's lease (ImportWindow#with_lease).
  #   A worker whose lease expired or was taken over gets StaleLease and writes nothing.
  # - Until the final transaction stages the validated snapshot and marks the window `validated`,
  #   the window is `fetching` or `validating`. An interruption leaves it there, and once the lease
  #   expires another worker starts it again from scratch.
  class WindowValidator
    MAX_SNAPSHOTS = 4 # at most 3 comparisons
    MAX_PAGES = 20    # bigger windows are split (4,000 plays)
    MAX_WINDOW_ATTEMPTS = 5 # claims of one window before it's left for review

    Outcome = Data.define(:status, :detail)

    def initialize(window:, client:, username:, session_key: nil, token: SecureRandom.uuid, clock: -> { Time.current })
      @window = window
      @client = client
      @username = username
      @session_key = session_key
      @token = token
      @clock = clock
    end

    def call
      HistoryImport.ensure_enabled!
      return outcome(:not_claimed, "window is not available to claim") unless @window.claim_for_validation!(@token, now: now)

      abandon_interrupted_fetches
      if @window.reload.attempts > MAX_WINDOW_ATTEMPTS
        return review("validation was attempted #{@window.attempts - 1} times without success", reason: "attempts_exhausted")
      end

      @budget = budget = RequestBudget.new(@client, previously_used: @window.budget_requests_used)
      # Renew the lease after every page: a short transaction between requests, never during one.
      fetcher = SnapshotFetcher.new(client: @client, username: @username, session_key: @session_key, budget: budget,
                                    max_pages: MAX_PAGES, on_page: -> { lease { nil } })
      range = @window.check_range # the whole window, or the part a sync checks
      previous = nil

      MAX_SNAPSHOTS.times do
        fetch = start_fetch(validating: previous.present?)
        result = begin
          fetcher.fetch(range)
        rescue SnapshotFetcher::Inconsistent => e
          finish_fetch(fetch, outcome: "mismatch", message: e.message)
          mark_mismatch(previous)
          previous = nil
          next
        rescue SnapshotFetcher::TooLarge => e
          finish_fetch(fetch, outcome: "failed", message: "#{e.message}; splitting the window")
          return split_or_review
        rescue SnapshotFetcher::BudgetExceeded => e
          finish_fetch(fetch, outcome: "failed", message: e.message)
          if budget.total_exhausted?
            return review("request budget for this window is used up across attempts (#{budget.total_used} of #{budget.total_limit} requests)",
                          reason: "budget_exhausted")
          end

          return fail_window(message: "#{e.message} (#{budget.used} of #{budget.limit} requests this run)", retryable: true)
        rescue Lastfm::Error => e
          finish_fetch(fetch, outcome: "failed", message: e.message, http_status: e.http_status, lastfm_error: e.code)
          return fail_window(message: e.message, http_status: e.http_status, lastfm_error: e.code, retryable: e.retryable?,
                             retry_after: e.retry_after)
        end

        snapshot = result.snapshot
        if (problem = snapshot_problem(snapshot))
          finish_fetch(fetch, outcome: "failed", message: problem.first, snapshot: snapshot)
          return review(problem.first, **problem.last)
        end

        record_snapshot(fetch, snapshot)
        if previous && previous[:snapshot].equivalent?(snapshot)
          settled, conflicts = previous[:snapshot].settle_ids(snapshot)
          return validated(fetch, previous[:fetch], settled, conflicts)
        end

        if previous
          summary = previous[:snapshot].difference_summary(snapshot)
          mark_mismatch(previous, message: "next snapshot differed: #{summary.to_json}")
        end
        previous = { fetch: fetch, snapshot: snapshot }
      end

      mark_mismatch(previous, message: "no later snapshot to compare with")
      review("snapshots kept changing after #{MAX_SNAPSHOTS} complete reads", reason: "unstable")
    rescue ImportWindow::StaleLease => e
      record_orphaned_requests
      outcome(:stale, e.message)
    end

    private

    def now = @clock.call

    def outcome(status, detail = nil) = Outcome.new(status: status, detail: detail)

    # Every write also adds the requests made since the last write to the window's persisted
    # count, so the budget survives validation restarts and job retries.
    def lease
      pending = unrecorded_requests
      result = @window.with_lease(@token, now: now) do |window|
        window.http_requests_used += pending
        yield window
      end
      @recorded_requests = @recorded_requests.to_i + pending
      result
    end

    def unrecorded_requests = @budget ? @budget.used - @recorded_requests.to_i : 0

    # A worker that lost its lease still spent those requests; they count against the window too.
    # One atomic increment, no other writes.
    def record_orphaned_requests
      count = unrecorded_requests
      return unless count.positive?

      ImportWindow.where(id: @window.id).update_all([ "http_requests_used = http_requests_used + ?", count ])
      @recorded_requests = @budget.used
    end

    # A previous worker died mid-fetch: its fetches are closed and their staged rows discarded.
    def abandon_interrupted_fetches
      lease do |window|
        stale = window.fetches.where(outcome: "in_progress")
        ImportWindowRow.where(import_window_fetch_id: stale.select(:id)).delete_all
        stale.update_all(outcome: "failed", error_message: "interrupted before validation finished", finished_at: now, updated_at: now)
      end
    end

    def start_fetch(validating:)
      lease do |window|
        window.state = validating ? "validating" : "fetching"
        attempt = (window.fetches.maximum(:attempt) || 0) + 1
        window.fetches.create!(attempt: attempt, started_at: now)
      end
    end

    def record_snapshot(fetch, snapshot)
      lease do
        fetch.update!(expected_total: snapshot.reported_total, row_count: snapshot.size, malformed_count: snapshot.malformed_count + snapshot.undated_count)
      end
    end

    def finish_fetch(fetch, outcome:, message: nil, http_status: nil, lastfm_error: nil, snapshot: nil)
      lease do
        fetch.update!(outcome: outcome, error_message: message, http_status: http_status, lastfm_error: lastfm_error,
                      finished_at: now, expected_total: snapshot&.reported_total || fetch.expected_total)
      end
    end

    def mark_mismatch(previous, message: nil)
      return unless previous

      finish_fetch(previous[:fetch], outcome: "mismatch", message: message || "a later read of the window differed")
    end

    # Rows Last.fm returned that we can't place safely: never accepted silently.
    # [message, { reason: }] for review.
    def snapshot_problem(snapshot)
      return [ "#{snapshot.undated_count} plays without a date", { reason: "undated_rows" } ] if snapshot.undated_count.positive?
      return [ "#{snapshot.malformed_count} malformed entries", { reason: "malformed_rows" } ] if snapshot.malformed_count.positive?
      return [ "#{snapshot.out_of_window_count} plays outside the requested range", { reason: "out_of_range_rows" } ] if snapshot.out_of_window_count.positive?

      nil
    end

    # Stages the validated snapshot, records any ID conflicts, and marks the window validated, in
    # one short transaction.
    def validated(fetch, matching_fetch, snapshot, conflicts = [])
      lease do |window|
        HistoryImport.ensure_enabled! # staging is history data too; insert_all bypasses model callbacks
        rows = snapshot.staging_rows.map { |row| row.merge(import_window_fetch_id: fetch.id) }
        rows.each_slice(1000) { |batch| ImportWindowRow.insert_all!(batch) }
        MbidDispute.record!(conflicts, window: window, now: now) if conflicts.any?
        matching_fetch.update!(outcome: "validated", finished_at: matching_fetch.finished_at || now)
        fetch.update!(outcome: "validated", finished_at: now)
        window.assign_attributes(state: "validated", validated_at: now, expected_total: snapshot.reported_total,
                                 fetched_count: snapshot.size, malformed_count: 0, claim_token: nil, lease_expires_at: nil, retry_at: nil,
                                 last_error_message: nil, last_http_status: nil, last_lastfm_error: nil)
      end
      outcome(:validated, "#{snapshot.size} plays#{", #{conflicts.size} with a disputed ID" if conflicts.any?}")
    end

    # `reason`: a code (ImportWindow::REVIEW_REASONS) that decides whether the stop is retried
    # automatically or waits for a person. A period never imported that stops for an integrity
    # reason is split instead, to isolate the problem (docs/milestone-2-plan.md §15.6); only a
    # period too small to split goes to review, as an explicit coverage gap.
    def review(message, reason:)
      return isolate(message) if isolatable?(reason)

      lease do |window|
        window.assign_attributes(state: "needs_review", review_reason: reason, last_error_message: message, claim_token: nil,
                                 lease_expires_at: nil, retry_at: nil)
      end
      outcome(:needs_review, message)
    end

    # Transient failures are retried later, with backoff, until the attempt ceiling. Permanent ones
    # (a rejected request, a response we can't use) stop at once: retrying would fail the same way.
    def fail_window(message:, http_status: nil, lastfm_error: nil, retryable: false, retry_after: nil)
      retry_at = (now + ImportWindow.retry_delay(@window.attempts, retry_after: retry_after) if retryable && @window.attempts < MAX_WINDOW_ATTEMPTS)
      lease do |window|
        window.assign_attributes(state: "failed", last_error_message: message, last_http_status: http_status,
                                 last_lastfm_error: lastfm_error, claim_token: nil, lease_expires_at: nil, retry_at: retry_at)
      end
      outcome(:failed, message)
    end

    def isolatable?(reason)
      @window.committed_at.nil? && @window.whole_window_checked? && WindowSplitter.splittable?(@window) &&
        !ImportWindow::TRANSIENT_REVIEW_REASONS.include?(reason) && reason != "too_large"
    end

    def isolate(message)
      children = lease do |window|
        window.last_error_message = "#{message}; split to isolate the problem"
        WindowSplitter.split!(window)
      end
      outcome(:split, "#{message}; split into #{children.size} windows to isolate the problem")
    end

    def split_or_review
      return review("window is too large but can't be split further", reason: "too_large") unless WindowSplitter.splittable?(@window)
      # Splitting would replace a committed month with uncommitted halves and lose its coverage.
      return review("a committed month grew beyond #{MAX_PAGES} pages; check it by hand", reason: "too_large") if @window.committed_at
      return review("the range checked is a part of this window and can't be split", reason: "too_large") unless @window.whole_window_checked?

      children = lease { |window| WindowSplitter.split!(window) }
      outcome(:split, "split into #{children.size} windows")
    end
  end
end
