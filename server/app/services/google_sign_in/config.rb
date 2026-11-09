module GoogleSignIn
  # The Google OAuth client's settings, read from the environment when used (docs/google-sign-in.md).
  # Google signs people in to Runout; it is never a listening source and no Google data is read.
  # Part of Runout's own sign-in: off while RUNOUT_PASSKEYS_ENABLED is off or the client is not set.
  module Config
    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth".freeze
    TOKEN_URL = "https://oauth2.googleapis.com/token".freeze
    JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs".freeze
    ISSUERS = [ "https://accounts.google.com", "accounts.google.com" ].freeze
    # Identity only: who signed in (`sub`) and, for display in Settings, their address. Nothing of
    # Gmail, Drive or any other Google data.
    SCOPES = %w[openid email].freeze

    module_function

    def client_id = ENV["GOOGLE_CLIENT_ID"].presence
    def client_secret = ENV["GOOGLE_CLIENT_SECRET"].presence
    def configured? = Passkeys.enabled? && client_id.present? && client_secret.present?

    # Always on the canonical origin, where the session cookie lives.
    def redirect_uri = "#{Rails.configuration.x.app_origin}/api/auth/google/callback"

    def authorize_url(state:, nonce:)
      query = { client_id: client_id, redirect_uri: redirect_uri, response_type: "code", scope: SCOPES.join(" "),
                state: state, nonce: nonce, prompt: "select_account" }
      "#{AUTHORIZE_URL}?#{URI.encode_www_form(query)}"
    end

    # The test suite sets config.x.google_sign_in_client; otherwise the real one.
    def client = Rails.configuration.x.google_sign_in_client || Client.new
  end
end
