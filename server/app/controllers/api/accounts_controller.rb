module Api
  # DELETE /api/account: erases the signed-in user and everything stored for them
  # (identities with the encrypted Last.fm session key, sessions, connection state; listening
  # history once it exists). Foreign keys cascade, so nothing is left behind.
  #
  # As the design requires for destructive actions, the user must type their Last.fm username.
  # Runout cannot revoke its access on Last.fm's side; the response links to where the user can.
  class AccountsController < ApplicationController
    LASTFM_APPLICATIONS_URL = "https://www.last.fm/settings/applications".freeze

    require_authentication

    def destroy
      username = Current.user.lastfm_identity&.username.to_s
      confirmation = params[:confirm_username].to_s
      unless username.present? && confirmation.casecmp?(username)
        return render json: { error: "confirmation_mismatch" }, status: :unprocessable_content
      end

      user = Current.user
      end_session
      user.destroy!
      render json: { deleted: true, revokeAccessUrl: LASTFM_APPLICATIONS_URL }
    end
  end
end
