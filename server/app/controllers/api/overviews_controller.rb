module Api
  # GET /api/overview?period=year:2014: the Overview for the signed-in user (Analytics::Overview),
  # from Runout's own stored plays. 409 while no plays are stored (the frontend's
  # "not connected" state); 400 for a period it can't read.
  class OverviewsController < ApplicationController
    require_authentication
    before_action :require_stored_plays

    def show
      period = begin
        Analytics::Period.parse(params[:period].presence || "all", time_zone: Current.user.reporting_timezone)
      rescue ArgumentError
        return render(json: { error: "invalid_period" }, status: :bad_request)
      end
      render json: Analytics::Overview.new(user: Current.user, period: period).call
    end
  end
end
