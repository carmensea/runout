module Api
  # GET /api/loved-tracks: the signed-in user's loved songs with their listening (Analytics::Loved).
  # 409 while no plays are stored.
  class LovedTracksController < ApplicationController
    require_authentication
    before_action :require_stored_plays

    def index
      render json: Analytics::Loved.new(user: Current.user).call
    end
  end
end
