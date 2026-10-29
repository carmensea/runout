class ApplicationController < ActionController::API
  include ActionController::Cookies
  include Authentication
  include RequestForgeryProtection

  before_action :prevent_caching

  private

  # Responses are per-user; never let a shared cache keep them.
  def prevent_caching
    response.headers["Cache-Control"] = "no-store"
  end
end
