module Api
  # Last.fm web authentication (https://www.last.fm/api/webauth).
  #
  # Last.fm's callback has no `state` parameter, so a one-time nonce is put into the callback
  # URL and also kept in a short-lived encrypted cookie; the callback must present both.
  class LastfmAuthController < ApplicationController
    STATE_COOKIE = :runout_lastfm_auth
    STATE_TTL = 10.minutes

    rate_limit to: 10, within: 1.minute, only: %i[start callback],
      with: -> { redirect_to "/overview?auth_error=rate_limited" }

    def start
      return redirect_to("/overview?auth_error=unavailable") unless Lastfm::Config.configured?
      # The state cookie and the session cookie are per host, and the callback lands on the canonical
      # origin, so sign-in started on another configured hostname moves there before anything is set.
      return redirect_to("#{app_origin}#{request.fullpath}", allow_other_host: true) if alternate_origin?

      nonce = SecureRandom.urlsafe_base64(32)
      cookies.encrypted[STATE_COOKIE] = {
        value: { "nonce" => nonce, "tz" => params[:tz].to_s.first(64) },
        expires: STATE_TTL.from_now,
        httponly: true,
        secure: Rails.env.production?,
        same_site: :lax,
        path: "/api/auth/lastfm"
      }
      callback = "#{app_origin}/api/auth/lastfm/callback?#{URI.encode_www_form(state: nonce)}"
      redirect_to Lastfm::Config.client.authorization_url(callback), allow_other_host: true
    end

    def callback
      stored = cookies.encrypted[STATE_COOKIE]
      cookies.delete(STATE_COOKIE, path: "/api/auth/lastfm")
      return fail_with("state") unless valid_state?(stored)
      return fail_with("denied") if params[:token].blank?

      result = Lastfm::SignIn.new(client: Lastfm::Config.client).call(token: params[:token], timezone: stored["tz"])
      start_session_for(result.user)
      redirect_to "/overview"
    rescue Lastfm::Error => e
      Rails.logger.warn("Last.fm sign-in failed: #{e.class.name} #{e.message}")
      fail_with(error_code(e))
    end

    private

    def app_origin = Rails.configuration.x.app_origin

    def alternate_origin?
      request.base_url != app_origin && Rails.configuration.x.app_origins.include?(request.base_url)
    end

    def valid_state?(stored)
      stored.is_a?(Hash) && stored["nonce"].present? && params[:state].present? &&
        ActiveSupport::SecurityUtils.secure_compare(stored["nonce"], params[:state].to_s)
    end

    # Each code has its own message in the frontend (src/pages/overview/OverviewPage.tsx).
    def error_code(error)
      case error
      when Lastfm::Error::TokenRejected then "denied"
      when Lastfm::SignIn::AccountNotAllowed then "account_not_allowed"
      when Lastfm::SignIn::RelinkRequired then "relink_required"
      when Lastfm::SignIn::IdentityChanged then "identity_changed"
      when Lastfm::SignIn::IdentityMismatch, Lastfm::SignIn::IdentityUnverifiable then "identity_unverified"
      when Lastfm::Error::Temporary then "lastfm_unavailable"
      when Lastfm::Error::ApiKeyRejected then "server_misconfigured"
      else "lastfm_rejected"
      end
    end

    def fail_with(code)
      redirect_to "/overview?#{URI.encode_www_form(auth_error: code)}"
    end
  end
end
