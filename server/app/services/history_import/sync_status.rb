module HistoryImport
  # Per period (window), three separate things (docs/milestone-2-plan.md §4.4, §5):
  # - coverage: imported at all (ImportCoverage; never lost to a later check or a disagreement);
  # - synchronisation: when it was last checked against Last.fm, and whether a check is running;
  # - review: unresolved differences (disputes, suspected or pending removals, reappeared plays).
  #
  # `status` sums them up, most urgent first:
  # - :checking: a check (or the first import of a period a sync added) is in progress;
  # - :check_stopped: the latest check went to review or gave up; stored plays are as before it;
  # - :inconsistent: the plays stored don't add up to the period's recorded count;
  # - :differences: something awaits a person;
  # - :suspected: a removal seen once, awaiting a second independent check;
  # - :synchronized: the whole period was confirmed by one validated snapshot within
  #   `fresh_within`, and nothing above applies;
  # - :count_matched: not verified recently, but Last.fm's count for the period equalled the plays
  #   stored at the last weekly comparison. A hint only: equal counts don't prove equal contents;
  # - :stale: neither.
  # A period is never :synchronized while differences or an unexplained count discrepancy remain.
  module SyncStatus
    Month = Data.define(:id, :from, :to, :status, :imported, :last_checked_at, :last_verified_at, :checking, :open_disputes,
                        :suspected_removals, :pending_removals, :reappeared, :committed_count, :present_count,
                        :count_checked_at, :remote_count, :last_error)

    module_function

    def for(user, fresh_within: Sync.config[:fresh_within], now: Time.current)
      ImportWindow.live.where(user: user).order(:window_from).map do |w|
        range = w.window_from...w.window_to
        removals = ScrobbleRemoval.unresolved.joins(:scrobble).where(user_id: user.id, scrobbles: { played_at: range })
                                  .group(:state).count
        disputes = ReconciliationDispute.open.where(user_id: user.id, played_at: range).count
        present = Scrobble.present.where(user_id: user.id).played_between(w.window_from, w.window_to).count
        stopped = w.state == "needs_review" || w.gave_up?
        checking = w.state != "committed" && !stopped
        verified = w.last_verified_at
        freshness = freshness(w, verified, present, now - fresh_within)
        Month.new(id: w.id, from: w.window_from, to: w.window_to, imported: w.committed_at.present?,
                  last_checked_at: w.last_checked_at || w.committed_at, last_verified_at: verified, checking: checking,
                  status: status(checking, disputes, removals, freshness, stopped: stopped,
                                 discrepancy: w.state == "committed" && present != w.committed_count),
                  open_disputes: disputes, suspected_removals: removals["observed"].to_i,
                  pending_removals: removals["pending_review"].to_i, reappeared: removals["reappeared"].to_i,
                  committed_count: w.committed_count, present_count: present, count_checked_at: w.count_checked_at,
                  remote_count: w.remote_count, last_error: (w.last_error_message if stopped || w.state == "failed"))
      end
    end

    # :fresh when the whole period was verified since `since`; :count_matched when only a count
    # comparison since then agreed with the plays stored now; otherwise :stale.
    def freshness(window, verified, present, since)
      return :fresh if verified && verified >= since
      return :count_matched if window.count_checked_at && window.count_checked_at >= since && window.remote_count == present

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
  end
end
