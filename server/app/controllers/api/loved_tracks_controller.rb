module Api
  # GET /api/loved-tracks: the signed-in user's loved songs with their listening (Analytics::Loved).
  # 409 when no listening account is connected.
  class LovedTracksController < ApplicationController
    require_authentication

    def index
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      render json: Analytics::Loved.new(user: Current.user).call
    end
  end
end
