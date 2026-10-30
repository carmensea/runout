module HistoryImport
  # The background half of the constant-cost status (docs/milestone-2-plan.md §15.7): counts the
  # plays present in every committed period of a user, in one grouped statement, and records the
  # result (present_count) and whether it disagrees with the period's committed_count
  # (count_mismatch_at, kept from the first time it was seen). SyncStatus reads those, so status
  # requests never count plays.
  #
  # Runs under the per-user lock that commits and review decisions take, so a count is never taken
  # halfway through a change to the same periods. Rows are touched only when a value changes.
  module CountCheck
    UPDATE_SQL = <<~SQL.freeze
      UPDATE import_windows w
         SET present_count = c.present,
             count_mismatch_at = CASE WHEN c.present = w.committed_count THEN NULL ELSE COALESCE(w.count_mismatch_at, :now) END,
             updated_at = :now
        FROM (SELECT w2.id, COUNT(s.id) FILTER (WHERE s.removed_at IS NULL) AS present
                FROM import_windows w2
                LEFT JOIN scrobbles s ON s.user_id = w2.user_id AND s.played_at >= w2.window_from AND s.played_at < w2.window_to
               WHERE w2.user_id = :user AND w2.state = 'committed'
               GROUP BY w2.id) c
       WHERE w.id = c.id AND w.state = 'committed'
         AND (w.present_count IS DISTINCT FROM c.present OR (c.present = w.committed_count) = (w.count_mismatch_at IS NOT NULL))
    SQL

    module_function

    # Returns { checked:, mismatched: } for the user.
    def run!(user_id, now: Time.current)
      HistoryImport.ensure_enabled!
      ImportWindow.uncached do
        ImportWindow.transaction do
          ImportWindow.connection.execute(ImportWindow.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "history:#{user_id}" ]))
          ImportWindow.connection.exec_update(ImportWindow.sanitize_sql_array([ UPDATE_SQL, { user: user_id, now: now } ]))
          scope = ImportWindow.live.committed.where(user_id: user_id)
          { checked: scope.count, mismatched: scope.where.not(count_mismatch_at: nil).count }
        end
      end
    end

    def run_all!(now: Time.current)
      ImportWindow.live.committed.distinct.pluck(:user_id).to_h { |user_id| [ user_id, run!(user_id, now: now) ] }
    end
  end
end
