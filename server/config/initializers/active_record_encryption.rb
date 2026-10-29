# Active Record Encryption protects provider credentials (the Last.fm session key).
#
# Production: keys must come from the environment (generate with `bin/rails db:encryption:init`).
# Development: keys are derived from the local secret_key_base (tmp/local_secret.txt, not committed).
# Test: fixed keys, which protect nothing and are used only for test data.
keys = {
  primary_key: ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"],
  deterministic_key: ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"],
  key_derivation_salt: ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"]
}

if keys.values.any?(&:blank?)
  if Rails.env.test?
    keys = { primary_key: "test-primary-key-0123456789abcdef", deterministic_key: "test-deterministic-key-0123456789",
             key_derivation_salt: "test-key-derivation-salt-012345" }
  elsif Rails.env.development?
    generator = ActiveSupport::KeyGenerator.new(Rails.application.secret_key_base, iterations: 1000)
    keys = keys.keys.index_with { |name| generator.generate_key("runout-ar-encryption-#{name}", 32).unpack1("H*") }
  else
    raise "Set ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY, ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY and " \
          "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT."
  end
end

ActiveRecord::Encryption.configure(**keys)
