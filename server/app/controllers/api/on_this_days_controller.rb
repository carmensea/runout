module Api
  # GET /api/on-this-day?date=2026-10-31: the same calendar date in the other years of the signed-in
  # user's history (Analytics::OnThisDay). 409 when no listening account is connected; 400 for a date
  # it can't read.
  class OnThisDaysController < ApplicationController
    require_authentication

    def show
      return render(json: { error: "not_connected" }, status: :conflict) unless Current.user.lastfm_connection

      date = begin
        Date.iso8601(params[:date].to_s)
      rescue Date::Error
        return render(json: { error: "invalid_date" }, status: :bad_request)
      end
      render json: Analytics::OnThisDay.new(user: Current.user, date: date).call
    end
  end
end
