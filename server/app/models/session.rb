# A signed-in browser. The cookie carries a random token; only its SHA-256 digest is stored,
# so a database leak does not expose usable session tokens.
class Session < ApplicationRecord
  LIFETIME = 30.days
  # An operator session (auth:sign_in_as) ends 60 minutes after it opened, whatever happens in it.
  OPERATOR_LIFETIME = 60.minutes
  # Sliding expiry never extends a session past this age; after it, sign in again.
  ABSOLUTE_LIFETIME = 90.days
  # Sliding expiry is refreshed at most this often, to avoid a write on every request.
  REFRESH_AFTER = 1.hour

  belongs_to :user

  scope :unexpired, -> { where("expires_at > ? AND created_at > ?", Time.current, ABSOLUTE_LIFETIME.ago) }

  # `operator`: opened through the operator's sign-in-as link; sees memories as placeholder words
  # and cannot write them (Memories::Placeholder).
  def self.start!(user:, ip_address:, user_agent:, operator: false)
    token = SecureRandom.urlsafe_base64(32)
    now = Time.current
    session = create!(
      user: user,
      token_digest: digest(token),
      expires_at: now + (operator ? OPERATOR_LIFETIME : LIFETIME),
      last_seen_at: now,
      ip_address: ip_address,
      user_agent: user_agent.to_s.first(255),
      operator: operator
    )
    [ session, token ]
  end

  def self.find_by_token(token)
    return nil if token.blank?

    unexpired.find_by(token_digest: digest(token))
  end

  def self.digest(token)
    OpenSSL::Digest::SHA256.hexdigest(token)
  end

  # Returns true when the expiry moved, so the caller can refresh the cookie.
  def touch_activity!
    return false if last_seen_at > REFRESH_AFTER.ago

    now = Time.current
    # An operator session is seen, never extended.
    return update_columns(last_seen_at: now, updated_at: now) && false if operator?

    update_columns(last_seen_at: now, expires_at: [ now + LIFETIME, created_at + ABSOLUTE_LIFETIME ].min, updated_at: now)
    true
  end
end
