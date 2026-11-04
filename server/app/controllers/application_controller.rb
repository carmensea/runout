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

  # Responses are per-user; never let a shared cache keep them.
  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end
end
