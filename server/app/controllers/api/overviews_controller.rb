module Api
  # GET /api/overview?period=year:2014: the Overview for the signed-in user (Analytics::Overview),
  # from Runout's own stored plays. 409 while no plays are stored (the frontend's
  # "not connected" state); 400 for a period it can't read.
  class OverviewsController < ApplicationController
    require_authentication
    before_action :require_stored_plays

    TTL = 1.day

    def show
      period = begin
        Analytics::Period.parse(params[:period].presence || "all", time_zone: Current.user.reporting_timezone)
      rescue ArgumentError
        return render(json: { error: "invalid_period" }, status: :bad_request)
      end
      render json: cached(period) { Analytics::Overview.new(user: Current.user, period: period).call }
    end

    private

    # The Overview is computed once per user, period and state of the history
    # (Analytics::HistoryVersion): a new play, a correction, a merge or a new cover changes the key,
    # so the next request computes afresh and the old answer is simply never asked for again. The
    # response itself stays `no-store` for the browser; this cache lives in the app process.
    def cached(period, &compute)
      user = Current.user
      key = [ "overview", user.id, user.reporting_timezone, period.serialized, period.from, period.to, Analytics::HistoryVersion.for(user) ]
      Rails.cache.fetch(key, expires_in: TTL, &compute)
    end
  end
end
