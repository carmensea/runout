module Api
  # PATCH /api/account: saves account-level preferences (the theme).
  # DELETE /api/account: erases the signed-in user and everything stored for them
  # (identities with the encrypted Last.fm session key, sessions, connection state; listening
  # history once it exists). Foreign keys cascade, so nothing is left behind.
  #
  # As the design requires for destructive actions, the user must type their name (the display name).
  # Runout cannot revoke its access on Last.fm's side; the response links to where the user can.
  class AccountsController < ApplicationController
    LASTFM_APPLICATIONS_URL = "https://www.last.fm/settings/applications".freeze
    SPOTIFY_APPS_URL = "https://www.spotify.com/account/apps/".freeze

    require_authentication

    # PATCH /api/account: preferences that follow the account. Only the theme so far.
    def update
      theme = params[:theme]
      return render json: { error: "unknown_theme" }, status: :unprocessable_content unless User::THEMES.include?(theme)

      Current.user.update!(theme: theme)
      render json: { theme: theme }
    end

    def destroy
      name = Current.user.display_name
      unless params[:confirm_name].to_s.casecmp?(name)
        return render json: { error: "confirmation_mismatch" }, status: :unprocessable_content
      end

      user = Current.user
      lastfm = user.lastfm_identity.present?
      spotify = user.listening_sources.where(provider: "spotify").exists?
      end_session
      user.destroy!
      # Where the person can also remove Runout on the services' side; null for a service they never connected.
      render json: { deleted: true, revokeAccessUrl: (LASTFM_APPLICATIONS_URL if lastfm), spotifyAppsUrl: (SPOTIFY_APPS_URL if spotify) }
    end
  end
end
