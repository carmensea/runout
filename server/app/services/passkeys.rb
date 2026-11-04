# The feature flag for Runout's own sign-in (RUNOUT_PASSKEYS_ENABLED). While off, every passkey,
# recovery and session route answers 404 and the operator task refuses to issue a link.
module Passkeys
  ENABLED_VALUES = %w[true 1].freeze

  module_function

  def enabled?
    ENABLED_VALUES.include?(Rails.configuration.x.passkeys_enabled.to_s.strip.downcase)
  end
end
