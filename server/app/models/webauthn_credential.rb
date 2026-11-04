# A passkey (docs/milestone-5-plan.md §2). `external_id` is the credential id the authenticator
# chose; `public_key` verifies its assertions; `sign_count` must only ever grow.
class WebauthnCredential < ApplicationRecord
  belongs_to :user

  validates :external_id, :public_key, presence: true

  scope :active, -> { where(revoked_at: nil) }

  def as_api_json
    { id: id, nickname: nickname, createdAt: created_at.iso8601, lastUsedAt: last_used_at&.iso8601, transports: transports }
  end
end
