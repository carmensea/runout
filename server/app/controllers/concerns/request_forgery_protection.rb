# State-changing requests must come from the origin they are sent to (one of the configured ones;
# never another hostname of the same app) and carry a header that a cross-site form cannot set.
# Combined with SameSite=Lax cookies this blocks CSRF without tokens.
module RequestForgeryProtection
  extend ActiveSupport::Concern

  SAFE_METHODS = %w[GET HEAD OPTIONS].freeze

  included do
    before_action :verify_same_origin_request
  end

  private

  def verify_same_origin_request
    return if SAFE_METHODS.include?(request.request_method)

    origin = request.headers["Origin"]
    origin_ok = origin == request.base_url && Rails.configuration.x.app_origins.include?(origin)
    header_ok = request.headers["X-Requested-With"] == "XMLHttpRequest"
    head :forbidden unless origin_ok && header_ok
  end
end
