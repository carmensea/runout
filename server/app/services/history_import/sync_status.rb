module HistoryImport
  # Per period (window), three separate things (docs/milestone-2-plan.md §4.4, §5):
  # - coverage: imported at all (ImportCoverage; never lost to a later check or a disagreement);
  # - synchronisation: when it was last checked against Last.fm, and whether a check is running;
  # - review: unresolved differences (disputes, suspected or pending removals, reappeared plays).
  #
  # `status` sums them up, most urgent first:
  # - :checking: a check (or the first import of a period a sync added) is in progress;
  # - :check_stopped: the latest check went to review or gave up; stored plays are as before it;
  # - :inconsistent: the last background count (CountCheck) found the plays stored don't add up to
  #   the period's recorded count;
  # - :differences: something awaits a person;
  # - :suspected: a removal seen once, awaiting a second independent check;
  # - :synchronized: the whole period was confirmed by one validated snapshot within
  #   `fresh_within`, and nothing above applies;
  # - :count_matched: not verified recently, but Last.fm's count for the period equalled the plays
  #   stored at the last weekly comparison. A hint only: equal counts don't prove equal contents;
  # - :stale: neither.
  # A period is never :synchronized while differences or an unexplained count discrepancy remain.
  #
  # Cost: three queries whatever the length of the history (the windows, open disputes per window,
  # unresolved removals per window and state). Plays are never counted here: counts come from the
  # maintained committed_count and the background measurements (docs/milestone-2-plan.md §15.7).
  module SyncStatus
    Month = Data.define(:id, :from, :to, :status, :state, :imported, :last_checked_at, :last_verified_at, :checking,
                        :open_disputes, :suspected_removals, :pending_removals, :reappeared, :committed_count,
                        :present_count, :count_checked_at, :remote_count, :review_reason, :last_error, :attempts,
                        :last_http_status, :last_lastfm_error)

    DISPUTES_SQL = <<~SQL.freeze
      SELECT w.id, COUNT(*) FROM reconciliation_disputes d
      JOIN import_windows w ON w.user_id = d.user_id AND d.played_at >= w.window_from AND d.played_at < w.window_to AND w.state <> 'split'
      WHERE d.user_id = :user AND d.state = 'open'
      GROUP BY w.id
    SQL
    REMOVALS_SQL = <<~SQL.freeze
      SELECT w.id, r.state, COUNT(*) FROM scrobble_removals r
      JOIN scrobbles s ON s.id = r.scrobble_id
      JOIN import_windows w ON w.user_id = r.user_id AND s.played_at >= w.window_from AND s.played_at < w.window_to AND w.state <> 'split'
      WHERE r.user_id = :user AND r.state IN (:states)
      GROUP BY w.id, r.state
    SQL

    module_function

    def for(user, fresh_within: Sync.config[:fresh_within], now: Time.current)
      user_id = user.is_a?(User) ? user.id : user
      windows = ImportWindow.live.where(user_id: user_id).order(:window_from).to_a
      return [] if windows.empty?

      disputes = select_rows(DISPUTES_SQL, user: user_id).to_h { |id, n| [ id, n ] }
      removals = select_rows(REMOVALS_SQL, user: user_id, states: ScrobbleRemoval::OPEN_STATES)
                 .each_with_object(Hash.new { |h, k| h[k] = {} }) { |(id, state, n), h| h[id][state] = n }
      windows.map { |w| month(w, disputes.fetch(w.id, 0), removals.fetch(w.id, {}), now - fresh_within) }
    end

    def month(w, disputes, removals, since)
      stopped = w.stopped?
      checking = w.state != "committed" && !stopped
      Month.new(id: w.id, from: w.window_from, to: w.window_to, state: w.state, imported: w.committed_at.present?,
                last_checked_at: w.last_checked_at || w.committed_at, last_verified_at: w.last_verified_at, checking: checking,
                status: status(checking, disputes, removals, freshness(w, since), stopped: stopped,
                               discrepancy: w.state == "committed" && w.count_mismatch_at.present?),
                open_disputes: disputes, suspected_removals: removals["observed"].to_i,
                pending_removals: removals["pending_review"].to_i, reappeared: removals["reappeared"].to_i,
                committed_count: w.committed_count, present_count: w.present_count, count_checked_at: w.count_checked_at,
                remote_count: w.remote_count, review_reason: (w.review_reason if w.state == "needs_review"),
                last_error: (w.last_error_message if stopped || w.state == "failed"), attempts: w.attempts,
                last_http_status: w.last_http_status, last_lastfm_error: w.last_lastfm_error)
    end

    # :fresh when the whole period was verified since `since`; :count_matched when only a count
    # comparison since then agreed with the plays stored at the time; otherwise :stale.
    def freshness(window, since)
      return :fresh if window.last_verified_at && window.last_verified_at >= since
      return :count_matched if window.count_checked_at && window.count_checked_at >= since && window.remote_count == window.present_count

      :stale
    end

    # `freshness`: :fresh, :count_matched or :stale.
    def status(checking, disputes, removals, freshness, stopped: false, discrepancy: false)
      return :checking if checking
      return :check_stopped if stopped
      return :inconsistent if discrepancy
      return :differences if disputes.positive? || removals["pending_review"].to_i.positive? || removals["reappeared"].to_i.positive?
      return :suspected if removals["observed"].to_i.positive?

      { fresh: :synchronized, count_matched: :count_matched, stale: :stale }.fetch(freshness)
    end

    def select_rows(sql, **binds)
      ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ sql, binds ]))
    end
  end
end
