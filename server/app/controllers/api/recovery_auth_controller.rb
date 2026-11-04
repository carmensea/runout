module Api
  # POST /api/auth/recovery: sign in with a single-use recovery code. The response says how many
  # passkeys the account has, so the app can insist on enrolling a new one.
  class RecoveryAuthController < ApplicationController
    before_action :require_passkeys_enabled
    rate_limit to: 5, within: 1.hour, with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

    def create
      user = RecoveryCode.redeem!(params[:code]) or return render(json: { error: "code_rejected" }, status: :unauthorized)
      start_session_for(user)
      render json: SessionState.for(user)
    end
  end
end
