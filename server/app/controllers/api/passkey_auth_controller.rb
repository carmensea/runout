module Api
  # Signing in with a passkey (docs/milestone-5-plan.md §2.3). Discoverable credentials: no
  # username, the authenticator says which credential it used and the server looks it up.
  class PasskeyAuthController < ApplicationController
    include WebauthnChallenge

    before_action :require_passkeys_enabled
    rate_limit to: 10, within: 1.minute, with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

    def options
      options = WebAuthn::Credential.options_for_get(user_verification: "required")
      store_challenge(:get, options.challenge)
      render json: options
    end

    def create
      challenge = take_challenge(:get) or return refuse("challenge_expired")
      credential = WebAuthn::Credential.from_get(credential_params)
      stored = WebauthnCredential.active.find_by(external_id: credential.id) or return refuse("passkey_rejected")
      return refuse("passkey_rejected") if credential.user_handle.present? && credential.user_handle != stored.user.webauthn_handle

      credential.verify(challenge, public_key: stored.public_key, sign_count: stored.sign_count, user_verification: true)
      stored.update!(sign_count: credential.sign_count, last_used_at: Time.current)
      start_session_for(stored.user)
      render json: SessionState.for(stored.user)
    rescue WebAuthn::SignCountVerificationError
      Rails.logger.warn("Passkey sign-in refused: sign count went backwards for credential #{stored&.id}")
      refuse("passkey_rejected")
    rescue WebAuthn::Error => e
      Rails.logger.warn("Passkey sign-in refused: #{e.class.name}")
      refuse("passkey_rejected")
    end

    private

    def refuse(code) = render(json: { error: code }, status: :unauthorized)
  end
end
