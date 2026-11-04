module Api
  # GET /api/auth/link/:token: the operator's emergency link (bin/rails auth:recovery_link), single
  # use and short-lived. No request can issue one.
  class SignInLinksController < ApplicationController
    before_action :require_passkeys_enabled
    rate_limit to: 10, within: 1.minute, with: -> { redirect_to "/overview?auth_error=rate_limited" }

    def show
      user = SignInLink.redeem!(params[:token]) or return redirect_to("/overview?auth_error=link_invalid")
      Rails.logger.warn("Operator sign-in link used for user #{user.id}")
      start_session_for(user)
      redirect_to "/overview"
    end
  end
end
