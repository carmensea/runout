module Api
  # GET /api/plays?period=day:2014-03-15&cursor=…&limit=100: every play in the period, in order,
  # a page at a time (Analytics::Plays). 409 when no listening account is connected; 400 for a period
  # or cursor it can't read.
  class PlaysController < ApplicationController
    require_authentication

    def index
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      period = begin
        Analytics::Period.parse(params[:period].to_s, time_zone: Current.user.reporting_timezone)
      rescue ArgumentError
        return render(json: { error: "invalid_period" }, status: :bad_request)
      end
      render json: Analytics::Plays.new(user: Current.user, period: period, cursor: params[:cursor],
                                        limit: params[:limit].presence || Analytics::Plays::LIMIT).call
    rescue Analytics::Plays::InvalidCursor
      render json: { error: "invalid_cursor" }, status: :bad_request
    end
  end
end
