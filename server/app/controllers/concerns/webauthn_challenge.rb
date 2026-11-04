# The challenge of a WebAuthn ceremony lives in a short-lived encrypted cookie between the options
# request and the verification, like the OAuth nonces. Each purpose (enrol, sign in) has its own
# cookie so one ceremony cannot answer the other.
module WebauthnChallenge
  extend ActiveSupport::Concern

  TTL = 5.minutes
  # The browser's PublicKeyCredential.toJSON(): nothing else is accepted.
  CREDENTIAL_KEYS = [ :id, :rawId, :type, :authenticatorAttachment,
                      { clientExtensionResults: {},
                        response: [ :clientDataJSON, :attestationObject, :authenticatorData, :signature, :userHandle, { transports: [] } ] } ].freeze

  private

  def credential_params
    params.require(:credential).permit(*CREDENTIAL_KEYS).to_h
  end

  def store_challenge(purpose, challenge)
    cookies.encrypted[challenge_cookie(purpose)] = {
      value: challenge, expires: TTL.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax, path: "/api"
    }
  end

  # Reads and clears the challenge; nil when there is none.
  def take_challenge(purpose)
    name = challenge_cookie(purpose)
    challenge = cookies.encrypted[name]
    cookies.delete(name, path: "/api")
    challenge.presence
  end

  def challenge_cookie(purpose) = :"runout_webauthn_#{purpose}"
end
