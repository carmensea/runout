module Api
  # Connecting Spotify (docs/spotify-plan.md §8), Authorization Code flow with the secret on the
  # server. Three steps, because Spotify requires a loopback IP redirect locally while the app and
  # its session cookie live on the app origin:
  #
  # 1. start (app origin, signed in): issues the encrypted `state` naming the user, and moves to
  # 2. begin (the redirect URI's origin): stores the state's nonce in a short-lived encrypted
  #    cookie on that origin, and sends the browser to Spotify;
  # 3. callback (same origin as 2): requires a valid, unexpired state and the matching cookie,
  #    exchanges the code, and returns to Settings.
  #
  # Tokens never reach the browser or the logs; errors return to Settings as a short code.
  class SpotifyAuthController < ApplicationController
    NONCE_COOKIE = :runout_spotify_auth
    COOKIE_PATH = "/api/auth/spotify".freeze

    rate_limit to: 10, within: 1.minute, only: %i[start begin_flow callback],
      with: -> { redirect_to settings_url(spotify_error: "rate_limited"), allow_other_host: true }

    def start
      return redirect_to(settings_url(spotify_error: "signed_out"), allow_other_host: true) unless Current.user
      return redirect_to(settings_url(spotify_error: "unavailable"), allow_other_host: true) unless Spotify::Config.configured?

      state, = Spotify::OAuthState.issue(Current.user.id)
      redirect_to "#{Spotify::Config.redirect_origin}#{COOKIE_PATH}/begin?#{URI.encode_www_form(state: state)}", allow_other_host: true
    end

    def begin_flow
      data = Spotify::OAuthState.read(params[:state])
      return fail_with("state") unless data && Spotify::Config.configured?

      cookies.encrypted[NONCE_COOKIE] = { value: data["n"], expires: Spotify::OAuthState::TTL.from_now, httponly: true,
                                          secure: request.ssl?, same_site: :lax, path: COOKIE_PATH }
      redirect_to Spotify::Config.authorize_url(state: params[:state]), allow_other_host: true
    end

    def callback
      nonce = cookies.encrypted[NONCE_COOKIE]
      cookies.delete(NONCE_COOKIE, path: COOKIE_PATH)
      data = Spotify::OAuthState.read(params[:state])
      return fail_with("state") unless data && nonce.is_a?(String) && ActiveSupport::SecurityUtils.secure_compare(nonce, data["n"])
      return fail_with(params[:error] == "access_denied" ? "denied" : "spotify_rejected") if params[:error].present? || params[:code].blank?

      user = User.find_by(id: data["u"]) or return fail_with("state")
      Spotify::Account.new.connect!(user: user, code: params[:code])
      redirect_to settings_url(spotify: "connected"), allow_other_host: true
    rescue Spotify::Account::AccountTaken then fail_with("account_taken")
    rescue Spotify::Account::InsufficientScope then fail_with("scope")
    rescue Spotify::Error::Forbidden then fail_with("forbidden")
    rescue Spotify::Error => e
      Rails.logger.warn("Spotify connection failed: #{e.class.name} #{e.message}")
      fail_with("spotify_unavailable")
    end

    private

    def fail_with(code) = redirect_to(settings_url(spotify_error: code), allow_other_host: true)

    def settings_url(**query) = "#{Rails.configuration.x.app_origin}/settings?#{URI.encode_www_form(query)}#sources"
  end
end
