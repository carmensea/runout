class ApplicationController < ActionController::API
  include ActionController::Cookies
  include Authentication
  include RequestForgeryProtection

  before_action :prevent_caching

  private

  # Routes of Runout's own sign-in exist only while the flag is on (Passkeys).
  def require_passkeys_enabled
    head :not_found unless Passkeys.enabled?
  end

  # The archive opens on stored plays, whatever account recorded them (docs/milestone-5-plan.md §2.4).
  # 409 not_connected is the frontend's "nothing to show yet" state.
  def require_stored_plays
    render(json: { error: "not_connected" }, status: :conflict) unless Current.user.scrobbles.exists?
  end

  # Responses are per-user; never let a shared cache keep them.
  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end
end
