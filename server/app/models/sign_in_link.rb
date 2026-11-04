# The operator's emergency sign-in: a single-use link issued over `railway ssh`
# (bin/rails auth:recovery_link), valid 15 minutes. Never issued by a web request.
class SignInLink < ApplicationRecord
  TTL = 15.minutes

  belongs_to :user

  def self.issue!(user)
    token = SecureRandom.urlsafe_base64(32)
    create!(user: user, token_digest: Session.digest(token), expires_at: TTL.from_now)
    token
  end

  def self.redeem!(token)
    return nil if token.blank?

    row = find_by(token_digest: Session.digest(token))
    return nil unless row && row.expires_at > Time.current &&
                      where(id: row.id, used_at: nil).update_all(used_at: Time.current) == 1

    row.user
  end
end
