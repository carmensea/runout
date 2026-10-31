module Api
  # GET /api/genres/:slug?period=year:2014: one genre in a period for the signed-in user
  # (Analytics::GenreDetail). 404 for an unknown genre, 400 for a period it can't read, 409 when no
  # listening account is connected.
  class GenresController < ApplicationController
    require_authentication

    def show
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      period = begin
        Analytics::Period.parse(params[:period].presence || "all", time_zone: Current.user.reporting_timezone)
      rescue ArgumentError
        return render(json: { error: "invalid_period" }, status: :bad_request)
      end
      render json: Analytics::GenreDetail.new(user: Current.user, period: period, slug: params[:slug]).call
    rescue Analytics::GenreDetail::UnknownGenre
      render json: { error: "unknown_genre" }, status: :not_found
    end
  end
end
