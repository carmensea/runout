module Api
  # GET /api/calendar: the signed-in user's whole history at a glance (Analytics::Calendar#history).
  # GET /api/calendar?from=2014-03-01&to=2014-03-31: plays per local day in that range, at most
  # Analytics::Calendar::MAX_DAYS days. 409 while no plays are stored; 400 for dates it
  # can't read.
  class CalendarsController < ApplicationController
    require_authentication
    before_action :require_stored_plays

    def show
      calendar = Analytics::Calendar.new(user: Current.user)
      return render(json: calendar.history) if params[:from].blank? && params[:to].blank?

      render json: calendar.days(Date.iso8601(params[:from].to_s), Date.iso8601(params[:to].to_s))
    rescue ArgumentError, Date::Error
      render json: { error: "invalid_range" }, status: :bad_request
    end
  end
end
