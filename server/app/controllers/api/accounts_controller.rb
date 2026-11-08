module Api
  # PATCH /api/account: saves account-level preferences (the theme, the display name).
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

    # PATCH /api/account { theme } or { displayName }: preferences that follow the account. The
    # display name is how the person is addressed and what they type to confirm deletion, and
    # what the operator tasks check against the account id; it names nobody else's data.
    def update
      changes = {}
      if params.key?(:theme)
        return render json: { error: "unknown_theme" }, status: :unprocessable_content unless User::THEMES.include?(params[:theme])

        changes[:theme] = params[:theme]
      end
      if params.key?(:displayName)
        name = params[:displayName].to_s.strip
        return render json: { error: "blank_name" }, status: :unprocessable_content if name.empty?
        return render json: { error: "name_too_long", max: User::NAME_MAX }, status: :unprocessable_content if name.length > User::NAME_MAX

        changes[:display_name] = name
      end
      return render json: { error: "nothing_to_save" }, status: :unprocessable_content if changes.empty?

      Current.user.update!(changes)
      render json: { theme: Current.user.theme, displayName: Current.user.display_name }
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
