# GET /api/session and the sign-in responses: who is signed in and which sign-in methods exist.
module SessionState
  module_function

  # `providers`: which outside sign-ins this server offers (Google, when its client is configured).
  def for(user)
    providers = { google: GoogleSignIn::Config.configured? }
    return { signedIn: false, providers: providers } unless user

    google = user.google_identity
    {
      signedIn: true,
      user: { displayName: user.display_name, timezone: user.reporting_timezone },
      methods: {
        passkeys: user.webauthn_credentials.active.count,
        recoveryCodes: user.recovery_codes.unused.count,
        lastfm: user.lastfm_identity.present? && user.lastfm_identity.revoked_at.nil?,
        google: google.present?,
        googleEmail: google&.username
      },
      providers: providers
    }
  end
end
