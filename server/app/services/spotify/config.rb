module Spotify
  # The Spotify app's settings, read from the environment when used, like Lastfm::Config
  # (docs/spotify-plan.md §8). The redirect URI must match the app's settings exactly; locally
  # Spotify requires a loopback IP (127.0.0.1), never "localhost". The secret stays on the server.
  module Config
    DEFAULT_REDIRECT_URI = "http://127.0.0.1:3000/api/auth/spotify/callback".freeze

    AUTHORIZE_URL = "https://accounts.spotify.com/authorize".freeze
    # Only what reading recently played tracks needs. GET /me needs no scope for id and display_name.
    SCOPES = %w[user-read-recently-played].freeze

    module_function

    def client_id = ENV["SPOTIFY_CLIENT_ID"].presence
    def client_secret = ENV["SPOTIFY_CLIENT_SECRET"].presence
    def redirect_uri = ENV["SPOTIFY_REDIRECT_URI"].presence || DEFAULT_REDIRECT_URI
    def configured? = client_id.present? && client_secret.present? && redirect_uri.present?

    # The origin the callback lands on (http://127.0.0.1:3000 locally).
    def redirect_origin
      uri = URI(redirect_uri)
      "#{uri.scheme}://#{uri.host}#{":#{uri.port}" unless uri.port == uri.default_port}"
    end

    def authorize_url(state:)
      query = { client_id: client_id, response_type: "code", redirect_uri: redirect_uri, scope: SCOPES.join(" "),
                state: state, show_dialog: "true" }
      "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
    end
  end
end
