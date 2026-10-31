module Api
  # GET /api/search?q=: artists, albums and tracks from the signed-in user's own listening history
  # (Analytics::Search). Never anything only another user played.
  class SearchesController < ApplicationController
    require_authentication

    def show
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      render json: Analytics::Search.new(user: Current.user, query: params[:q].to_s).call
    end
  end
end
