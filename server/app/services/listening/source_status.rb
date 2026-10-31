module Listening
  # What Settings shows about listening sources (docs/spotify-plan.md §7). Never credentials.
  module SourceStatus
    module_function

    def for(user)
      source = user.listening_sources.spotify.order(Arel.sql("state = 'disconnected'"), updated_at: :desc).first
      {
        lastfm: { role: "archive", connected: user.lastfm_identity.present?, username: user.lastfm_identity&.username },
        spotify: spotify(source)
      }
    end

    def spotify(source)
      base = { configured: Spotify::Config.configured?, ingestionEnabled: ListeningStorage.enabled?("spotify") }
      return base.merge(state: "not_connected", account: nil) unless source

      base.merge(state: source.state, account: { id: source.external_account_id, displayName: source.display_name },
                 connectedAt: source.connected_at.iso8601, disconnectedAt: source.disconnected_at&.iso8601,
                 lastError: source.last_error, lastErrorAt: source.last_error_at&.iso8601)
    end
  end
end
