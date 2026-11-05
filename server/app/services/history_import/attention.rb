module HistoryImport
  # What needs the owner's action (docs/milestone-2-plan.md §15.3): the count shown in the
  # connection banner. Counted:
  # - review items: removals pending review, reappeared plays, open disputes;
  # - periods stopped for an integrity reason (transient stops are retried automatically, so they
  #   aren't actionable), and periods whose background count disagrees with their recorded count;
  # - an account problem that stopped synchronisation, or a listening source whose permission was
  #   lost (`needs_reauth`), so a revoked Spotify connection shows on every page.
  # Not counted: background work in progress, removals seen only once (they wait for a second
  # independent check), and catalogue matching suggestions.
  module Attention
    STOPPED_SQL = <<~SQL.squish.freeze
      (state = 'needs_review' AND (review_reason IS NULL OR review_reason NOT IN (:transient)))
      OR (state = 'committed' AND count_mismatch_at IS NOT NULL)
    SQL

    # One query: a failed Last.fm connection counts once, each source that lost its permission once.
    ACCOUNT_SQL = <<~SQL.squish.freeze
      SELECT (SELECT count(*) FROM lastfm_connections WHERE user_id = :user AND history_state = 'failed')
           + (SELECT count(*) FROM listening_sources WHERE user_id = :user AND state = 'needs_reauth')
    SQL

    module_function

    # Four queries whatever the length of the history.
    def for(user)
      reviews = ScrobbleRemoval.where(user_id: user.id, state: %w[pending_review reappeared]).count +
                ReconciliationDispute.open.where(user_id: user.id).count
      periods = ImportWindow.live.where(user_id: user.id).where(STOPPED_SQL, transient: ImportWindow::TRANSIENT_REVIEW_REASONS).count
      account = ActiveRecord::Base.connection.select_value(ActiveRecord::Base.sanitize_sql_array([ ACCOUNT_SQL, { user: user.id } ])).to_i
      { reviews: reviews, periods: periods, account: account, total: reviews + periods + account }
    end

    # The same rules for one period, as SyncStatus reports it.
    def actionable_period?(month)
      (month.state == "needs_review" && !ImportWindow::TRANSIENT_REVIEW_REASONS.include?(month.review_reason)) || month.status == :inconsistent
    end
  end
end
