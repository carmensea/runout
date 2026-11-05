# A single-use, expiring sign-in link the operator issues (bin/rails auth:recovery_link,
# auth:invite_link). Only the token's SHA-256 digest is stored.
class SignInLink < ApplicationRecord
  TTL = 15.minutes          # recovery: handed over at once, in an emergency
  INVITATION_TTL = 24.hours # invitation: opened when the invited person gets to it
  KINDS = %w[recovery invitation].freeze

  belongs_to :user

  validates :kind, inclusion: { in: KINDS }

  def self.issue!(user, kind: "recovery")
    token = SecureRandom.urlsafe_base64(32)
    ttl = kind == "invitation" ? INVITATION_TTL : TTL
    create!(user: user, kind: kind, token_digest: Session.digest(token), expires_at: ttl.from_now)
    token
  end

  # The link, now used, when it was valid; nil otherwise. An invitation is scoped to enrolment:
  # once its account has an active passkey it is dead even if it was never opened.
  def self.redeem!(token)
    return nil if token.blank?

    row = find_by(token_digest: Session.digest(token))
    return nil unless row && row.expires_at > Time.current
    return nil if row.kind == "invitation" && row.user.webauthn_credentials.active.exists?
    return nil unless where(id: row.id, used_at: nil).update_all(used_at: Time.current) == 1

    row
  end
end
