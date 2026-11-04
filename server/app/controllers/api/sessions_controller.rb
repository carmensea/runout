module Api
  # The signed-in browser's own session: who it is (GET, docs/milestone-5-plan.md §2.3) and sign-out.
  class SessionsController < ApplicationController
    before_action :require_passkeys_enabled, only: :show
    require_authentication only: :destroy

    def show
      render json: SessionState.for(Current.user)
    end

    def destroy
      end_session
      head :no_content
    end
  end
end
