module Api
  # GET /api/sessions, DELETE /api/sessions/:id: the signed-in person's other browsers.
  class BrowserSessionsController < ApplicationController
    before_action :require_passkeys_enabled
    require_authentication

    def index
      sessions = Current.user.sessions.unexpired.order(last_seen_at: :desc).map do |s|
        { id: s.id, current: s.id == Current.session.id, createdAt: s.created_at.iso8601, lastSeenAt: s.last_seen_at.iso8601,
          ipAddress: s.ip_address, userAgent: s.user_agent }
      end
      render json: { sessions: sessions }
    end

    def destroy
      session = Current.user.sessions.find_by(id: params[:id]) or return head(:not_found)
      session.id == Current.session.id ? end_session : session.destroy!
      head :no_content
    end
  end
end
