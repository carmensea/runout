module Api
  # GET /api/search?q=: artists, albums and tracks from the signed-in user's own listening history
  # (Analytics::Search). Never anything only another user played.
  class SearchesController < ApplicationController
    require_authentication
    before_action :require_stored_plays

    def show
      render json: Analytics::Search.new(user: Current.user, query: params[:q].to_s).call
    end
  end
end
