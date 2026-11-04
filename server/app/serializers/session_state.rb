# GET /api/session and the sign-in responses: who is signed in and which sign-in methods exist.
module SessionState
  module_function

  def for(user)
    return { signedIn: false } unless user

    {
      signedIn: true,
      user: { displayName: user.display_name, timezone: user.reporting_timezone },
      methods: {
        passkeys: user.webauthn_credentials.active.count,
        recoveryCodes: user.recovery_codes.unused.count,
        lastfm: user.lastfm_identity.present? && user.lastfm_identity.revoked_at.nil?
      }
    }
  end
end
