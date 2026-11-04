module Api
  # POST /api/recovery-codes: a signed-in person replaces their recovery codes. The plaintext is
  # returned once and never stored.
  class RecoveryCodesController < ApplicationController
    before_action :require_passkeys_enabled
    require_authentication

    def create
      render json: { recoveryCodes: RecoveryCode.regenerate!(Current.user) }, status: :created
    end
  end
end
