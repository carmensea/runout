# An expiring sign-in link the operator issues: single use for recovery (bin/rails auth:recovery_link)
# and for the operator's own sign-in-as (auth:sign_in_as, kind "operator", which opens an operator
# session), reusable until enrolment for an invitation (auth:invite_link). Only the token's SHA-256
# digest is stored.
class SignInLink < ApplicationRecord
  TTL = 15.minutes          # recovery: handed over at once, in an emergency
  INVITATION_TTL = 24.hours # invitation: opened when the invited person gets to it
  KINDS = %w[recovery invitation operator].freeze

  belongs_to :user

  validates :kind, inclusion: { in: KINDS }

  def self.issue!(user, kind: "recovery")
    token = SecureRandom.urlsafe_base64(32)
    ttl = kind == "invitation" ? INVITATION_TTL : TTL
    create!(user: user, kind: kind, token_digest: Session.digest(token), expires_at: ttl.from_now)
    token
  end

  # The link when it was valid; nil otherwise. A recovery link works once. An invitation is
  # scoped to enrolment: it opens for whoever has it until its account has an active passkey or
  # it expires, and `used_at` keeps the first opening.
  # shortcut: invitations were single use, but chat apps fetch links for previews and spent
  # them before the invited person could click (Discordbot, 2026-11-07); single use returns when
  # the redeem happens on a POST from the welcome page rather than on the GET.
  def self.redeem!(token)
    return nil if token.blank?

    row = find_by(token_digest: Session.digest(token))
    return nil unless row && row.expires_at > Time.current

    if row.kind == "invitation"
      return nil if row.user.sign_in_method?

      where(id: row.id, used_at: nil).update_all(used_at: Time.current)
      return row
    end

    return nil unless where(id: row.id, used_at: nil).update_all(used_at: Time.current) == 1

    row
  end
end
