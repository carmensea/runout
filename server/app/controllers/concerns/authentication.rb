# Cookie-backed application sessions. The cookie holds a random token; the database stores
# only its SHA-256 digest (see Session).
module Authentication
  extend ActiveSupport::Concern

  COOKIE_NAME = Rails.env.production? ? "__Host-runout_session" : "runout_session"

  included do
    before_action :resume_session
  end

  class_methods do
    def require_authentication(**options)
      before_action :require_authenticated_user, **options
    end
  end

  private

  def resume_session
    Current.session = Session.find_by_token(cookies[COOKIE_NAME])
    if Current.session
      write_session_cookie(cookies[COOKIE_NAME], Current.session.expires_at) if Current.session.touch_activity!
    elsif cookies[COOKIE_NAME].present?
      # Expired, revoked or tampered: drop the stale cookie.
      cookies.delete(COOKIE_NAME, path: "/")
    end
  end

  def require_authenticated_user
    head :unauthorized unless Current.user
  end

  # Rotates the session on sign-in so a pre-existing cookie can never be promoted (fixation).
  def start_session_for(user)
    Session.find_by_token(cookies[COOKIE_NAME])&.destroy
    session, token = Session.start!(user: user, ip_address: request.remote_ip, user_agent: request.user_agent)
    write_session_cookie(token, session.expires_at)
    Current.session = session
  end

  def end_session
    Current.session&.destroy
    Current.session = nil
    cookies.delete(COOKIE_NAME, path: "/")
  end

  def write_session_cookie(token, expires_at)
    cookies[COOKIE_NAME] = {
      value: token,
      expires: expires_at,
      httponly: true,
      secure: Rails.env.production?,
      same_site: :lax,
      path: "/"
    }
  end
end
