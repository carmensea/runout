# Passkeys are bound to the relying party id: the canonical origin's host (runout.idlewinny.com in
# production, localhost in development). Only that origin may enrol or use them; the Railway
# fallback hostname cannot (docs/milestone-5-plan.md §2.3).
WebAuthn.configure do |config|
  config.allowed_origins = [ Rails.configuration.x.app_origin ]
  config.rp_name = "Runout"
  config.rp_id = URI(Rails.configuration.x.app_origin).host
end
