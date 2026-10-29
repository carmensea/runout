module Api
  class SessionsController < ApplicationController
    require_authentication

    def destroy
      end_session
      head :no_content
    end
  end
end
