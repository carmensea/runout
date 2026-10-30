module HistoryImport
  # Per imported month, three separate things (docs/milestone-2-plan.md §4.4):
  # - coverage: imported at all (ImportCoverage; never lost to a later check or a disagreement);
  # - synchronisation: when it was last checked against Last.fm, and whether a check is running;
  # - review: unresolved differences (disputes, suspected or pending removals, reappeared plays).
  #
  # `status` sums them up, most urgent first: :checking, :differences (something awaits a person),
  # :suspected (a removal seen once, awaiting a second independent check), :stale (not checked
  # within `fresh_within`), :synchronized. A month is never :synchronized while differences remain.
  module SyncStatus
    Month = Data.define(:from, :to, :status, :last_checked_at, :checking, :open_disputes, :suspected_removals,
                        :pending_removals, :reappeared)

    module_function

    def for(user, fresh_within: 30.days, now: Time.current)
      ImportWindow.live.imported.where(user: user).order(:window_from).map do |w|
        range = w.window_from...w.window_to
        removals = ScrobbleRemoval.unresolved.joins(:scrobble).where(user_id: user.id, scrobbles: { played_at: range })
                                  .group(:state).count
        disputes = ReconciliationDispute.open.where(user_id: user.id, played_at: range).count
        checked = w.last_checked_at || w.committed_at
        checking = w.state != "committed"
        Month.new(from: w.window_from, to: w.window_to, status: status(checking, disputes, removals, checked < now - fresh_within),
                  last_checked_at: checked, checking: checking,
                  open_disputes: disputes, suspected_removals: removals["observed"].to_i,
                  pending_removals: removals["pending_review"].to_i, reappeared: removals["reappeared"].to_i)
      end
    end

    def status(checking, disputes, removals, stale)
      return :checking if checking
      return :differences if disputes.positive? || removals["pending_review"].to_i.positive? || removals["reappeared"].to_i.positive?
      return :suspected if removals["observed"].to_i.positive?

      stale ? :stale : :synchronized
    end
  end
end
