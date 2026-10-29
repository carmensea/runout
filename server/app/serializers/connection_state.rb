# Shapes the ConnectionState union from src/data/types.ts.
module ConnectionState
  module_function

  def for(user)
    identity = user&.lastfm_identity
    connection = user&.lastfm_connection
    return { status: "none" } if identity.nil? || identity.revoked_at || connection.nil?

    base = { username: identity.username, timezone: user.reporting_timezone }
    case connection.history_state
    when "not_started" then base.merge(status: "connected")
    when "failed" then base.merge(status: "failed", lastSyncedAt: connection.last_synced_at&.iso8601, message: connection.last_error.to_s)
    when "imported" then base.merge(status: "synced", lastSyncedAt: connection.last_synced_at&.iso8601)
    else base.merge(status: "importing", progress: 0)
    end
  end
end
