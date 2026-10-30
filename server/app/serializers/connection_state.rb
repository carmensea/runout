# Shapes the ConnectionState union from src/data/types.ts.
#
# `attention` counts what needs the owner (HistoryImport::Attention): review items, periods
# stopped for an integrity reason, count discrepancies, an account problem. Background work and
# automatic retries are not counted. `syncPaused`: the owner paused automatic synchronisation.
module ConnectionState
  module_function

  def for(user)
    identity = user&.lastfm_identity
    connection = user&.lastfm_connection
    return { status: "none" } if identity.nil? || identity.revoked_at || connection.nil?

    base = { username: identity.username, timezone: user.reporting_timezone }
    case connection.history_state
    when "not_started" then base.merge(status: "connected")
    when "failed"
      base.merge(status: "failed", lastSyncedAt: last_synced_at(user, connection), message: connection.last_error.to_s,
                 attention: HistoryImport::Attention.for(user)[:total])
    when "imported"
      base.merge(status: "synced", lastSyncedAt: last_synced_at(user, connection), syncPaused: connection.sync_paused_at.present?,
                 attention: HistoryImport::Attention.for(user)[:total])
    else
      percent = HistoryImport::Progress.for(user).percent
      base.merge(status: "importing", progress: percent ? percent / 100.0 : 0, attention: HistoryImport::Attention.for(user)[:total])
    end
  end

  # The last successful sync, or the end of the full import before the first sync.
  def last_synced_at(user, connection)
    (connection.last_synced_at || ImportRun.where(user_id: user.id, kind: "full", state: "completed").maximum(:finished_at))&.iso8601
  end
end
