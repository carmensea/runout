module Api
  # GET /api/auth/link/:token: the operator's emergency link (bin/rails auth:recovery_link) or an
  # invitation (auth:invite_link), single use and expiring. No request can issue one.
  class SignInLinksController < ApplicationController
    before_action :require_passkeys_enabled
    rate_limit to: 10, within: 1.minute, with: -> { redirect_to "/overview?auth_error=rate_limited" }

    def show
      link = SignInLink.redeem!(params[:token]) or return redirect_to("/overview?auth_error=link_invalid")
      Rails.logger.warn("Operator #{link.kind} link used for user #{link.user_id}")
      start_session_for(link.user)
      # An invited person lands on the onboarding page: passkey, recovery codes, a source.
      redirect_to(link.kind == "invitation" ? "/welcome" : "/overview")
    end
  end
end
