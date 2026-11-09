module Api
  # Google sign-in (docs/google-sign-in.md): OpenID Connect, Authorization Code flow, with the
  # secret and all verification on the server. Google only says who is at the keyboard; Runout's
  # own session (Authentication) does the rest, unchanged.
  #
  # One flow, two intents, fixed when it starts and carried in a short-lived encrypted cookie
  # together with the `state` and the ID token's `nonce`:
  # - `sign_in`: a Google account already linked to a Runout account opens a session for it. A
  #   Google account nobody linked signs nobody in and creates nothing: Runout is invitation-only.
  # - `link`: the signed-in person attaches Google to their own account (Settings, or the welcome
  #   page of an invitation). The cookie names the account that started, and the callback requires
  #   the same account's session, so a link can't be completed for, or by, anybody else.
  #
  # Linking and unlinking need a session that authenticated recently (FRESH), except for an invited
  # account that has no sign-in method yet, whose only proof is the invitation it just opened.
  # Operator sessions never reach this controller (Authentication::OPERATOR_BLOCKED_CONTROLLERS).
  class GoogleAuthController < ApplicationController
    STATE_COOKIE = :runout_google_auth
    COOKIE_PATH = "/api/auth/google".freeze
    STATE_TTL = 10.minutes
    FRESH = 10.minutes
    INTENTS = %w[sign_in link].freeze
    RETURNS = %w[overview settings welcome].freeze

    before_action :require_google_sign_in
    require_authentication only: :destroy
    rate_limit to: 10, within: 1.minute, only: %i[start callback], with: -> { redirect_to "/overview?auth_error=rate_limited" }

    def start
      # The state cookie and the session cookie are per host, and the callback lands on the canonical
      # origin, so a flow started on another configured hostname moves there before anything is set.
      return redirect_to("#{app_origin}#{request.fullpath}", allow_other_host: true) if alternate_origin?

      intent = INTENTS.include?(params[:intent]) ? params[:intent] : "sign_in"
      back = RETURNS.include?(params[:return]) ? params[:return] : "overview"
      if intent == "link"
        return finish(back, error: "signed_out") unless Current.user
        return finish(back, error: "confirm_first") unless may_change_methods?
      end

      state = SecureRandom.urlsafe_base64(32)
      nonce = SecureRandom.urlsafe_base64(32)
      cookies.encrypted[STATE_COOKIE] = {
        value: { "state" => state, "nonce" => nonce, "intent" => intent, "return" => back, "user" => (Current.user.id if intent == "link") },
        expires: STATE_TTL.from_now, httponly: true, secure: Rails.env.production?, same_site: :lax, path: COOKIE_PATH
      }
      redirect_to GoogleSignIn::Config.authorize_url(state: state, nonce: nonce), allow_other_host: true
    end

    def callback
      stored = cookies.encrypted[STATE_COOKIE]
      cookies.delete(STATE_COOKIE, path: COOKIE_PATH)
      return finish("overview", error: "state") unless valid_state?(stored)

      back = stored["return"]
      return finish(back, error: params[:error] == "access_denied" ? "denied" : "failed") if params[:error].present? || params[:code].blank?

      verified = GoogleSignIn::Config.client.identity_for(code: params[:code].to_s, nonce: stored["nonce"])
      stored["intent"] == "link" ? link(verified, stored, back) : sign_in(verified, back)
    rescue GoogleSignIn::Client::Error => e
      Rails.logger.warn("Google sign-in failed: #{e.class.name}")
      finish(back || "overview", error: "failed")
    end

    # DELETE /api/auth/google: unlink. Needs a fresh session; refused for the last way in.
    def destroy
      return render(json: { error: "confirm_first" }, status: :forbidden) unless may_change_methods?

      GoogleSignIn::Account.unlink!(Current.user, keep: Current.session)
      head :no_content
    rescue GoogleSignIn::Account::LastMethod
      render json: { error: "last_method" }, status: :conflict
    end

    private

    def require_google_sign_in
      head :not_found unless GoogleSignIn::Config.configured?
    end

    def sign_in(verified, back)
      user = GoogleSignIn::Account.sign_in(verified) or return finish(back, error: "no_account")
      start_session_for(user)
      finish(back == "welcome" ? "overview" : back)
    end

    # The session must still be the one that started the link: same account, and allowed to change
    # its sign-in methods.
    def link(verified, stored, back)
      return finish(back, error: "signed_out") unless Current.user && Current.user.id == stored["user"]
      return finish(back, error: "confirm_first") unless may_change_methods?

      GoogleSignIn::Account.link!(Current.user, verified)
      Rails.logger.info("Google linked to user #{Current.user.id}")
      finish(back, linked: true)
    rescue GoogleSignIn::Account::Unavailable then finish(back, error: "unavailable")
    rescue GoogleSignIn::Account::AlreadyLinked then finish(back, error: "already_linked")
    end

    # Fresh authentication, or an invited account that has nothing to protect yet.
    def may_change_methods?
      Current.session.created_at > FRESH.ago || !Current.user.sign_in_method?
    end

    def valid_state?(stored)
      stored.is_a?(Hash) && stored["state"].present? && params[:state].present? &&
        ActiveSupport::SecurityUtils.secure_compare(stored["state"], params[:state].to_s) &&
        INTENTS.include?(stored["intent"]) && RETURNS.include?(stored["return"])
    end

    # Back to the app with a short code; never a token, never a reason that names anyone.
    def finish(back, error: nil, linked: false)
      query = error ? { google_error: error } : (linked ? { google: "linked" } : {})
      path = { "settings" => "/settings", "welcome" => "/welcome" }.fetch(back, "/overview")
      path = "/overview" if error == "signed_out"
      url = "#{app_origin}#{path}#{"?#{URI.encode_www_form(query)}" if query.any?}#{'#sign-in' if back == 'settings' && error != 'signed_out'}"
      redirect_to url, allow_other_host: true
    end

    def app_origin = Rails.configuration.x.app_origin

    def alternate_origin?
      request.base_url != app_origin && Rails.configuration.x.app_origins.include?(request.base_url)
    end
  end
end
