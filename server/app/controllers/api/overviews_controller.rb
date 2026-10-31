module Api
  # GET /api/overview?period=year:2014: the Overview for the signed-in user (Analytics::Overview),
  # from Runout's own stored plays. 409 when no listening account is connected (the frontend's
  # "not connected" state); 400 for a period it can't read.
  class OverviewsController < ApplicationController
    require_authentication

    def show
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      period = Analytics::Period.parse(params[:period].presence || "all", time_zone: Current.user.reporting_timezone)
      render json: Analytics::Overview.new(user: Current.user, period: period).call
    rescue ArgumentError
      render json: { error: "invalid_period" }, status: :bad_request
    end
  end
end
