# Shapes the ConnectionState union from src/data/types.ts. `signed_out` for no session; `none` for a
# signed-in account without a Last.fm connection (the archive still opens on stored plays).
#
# `attention` counts what needs the owner (HistoryImport::Attention): review items, periods
# stopped for an integrity reason, count discrepancies, an account problem. Background work and
# automatic retries are not counted. `syncPaused`: the owner paused automatic synchronisation.
module ConnectionState
  module_function

  # `session`: the current one; an operator session (auth:sign_in_as) is reported with its end, so
  # the frontend shows the operator banner and hides the controls the server would refuse anyway.
  def for(user, session: nil)
    return { status: "signed_out" } if user.nil?

    account = { displayName: user.display_name, timezone: user.reporting_timezone, theme: user.theme, features: user.features }
    account[:operator] = { expiresAt: session.expires_at.utc.iso8601 } if session&.operator?
    identity = user.lastfm_identity
    connection = user.lastfm_connection
    return account.merge(status: "none") if identity.nil? || identity.revoked_at || connection.nil?

    base = account.merge(username: identity.username)
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
