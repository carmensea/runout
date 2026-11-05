module Api
  # A signed-in person's passkeys (docs/milestone-5-plan.md §2.3): list, enrol, revoke. Enrolment is
  # the only way a credential is ever attached to a user, and it needs an existing session.
  class PasskeysController < ApplicationController
    include WebauthnChallenge

    before_action :require_passkeys_enabled
    require_authentication

    def index
      render json: { passkeys: Current.user.webauthn_credentials.active.order(:created_at).map(&:as_api_json) }
    end

    def options
      user = Current.user
      user.update!(webauthn_handle: WebAuthn.generate_user_handle) if user.webauthn_handle.blank?
      options = WebAuthn::Credential.options_for_create(
        user: { id: user.webauthn_handle, name: user.display_name, display_name: user.display_name },
        exclude: user.webauthn_credentials.active.pluck(:external_id),
        authenticator_selection: { resident_key: "required", user_verification: "required" }
      )
      store_challenge(:create, options.challenge)
      render json: options
    end

    def create
      challenge = take_challenge(:create) or return render(json: { error: "challenge_expired" }, status: :unprocessable_content)
      credential = WebAuthn::Credential.from_create(credential_params)
      credential.verify(challenge, user_verification: true)

      user = Current.user
      passkey = user.webauthn_credentials.create!(
        external_id: credential.id, public_key: credential.public_key, sign_count: credential.sign_count,
        nickname: params[:nickname].to_s.strip.first(60).presence, transports: Array(credential.response.transports)
      )
      # A set of codes comes with the first passkey. Enrolling never replaces usable codes: a new set
      # is made only when none is left (never made, or all used), and the person is shown it once.
      codes = user.recovery_codes.unused.none? ? RecoveryCode.regenerate!(user) : nil
      render json: { passkey: passkey.as_api_json, recoveryCodes: codes }, status: :created
    rescue WebAuthn::Error => e
      Rails.logger.warn("Passkey enrolment refused: #{e.class.name}")
      render json: { error: "passkey_rejected" }, status: :unprocessable_content
    end

    def destroy
      passkey = Current.user.webauthn_credentials.active.find_by(id: params[:id]) or return head(:not_found)
      if Current.user.webauthn_credentials.active.where.not(id: passkey.id).none? && Current.user.recovery_codes.unused.none?
        return render json: { error: "last_passkey" }, status: :conflict
      end

      passkey.update!(revoked_at: Time.current)
      head :no_content
    end
  end
end
