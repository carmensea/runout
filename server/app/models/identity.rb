# A way of signing in. For Last.fm (docs/backend-plan.md §2):
# - `uid` is the normalised (lowercased) username: a lookup key that only an explicit relink
#   (bin/rails lastfm:relink) changes. Last.fm exposes no stable numeric account ID.
# - `registered_at` is the account's registration time, checked on every sign-in as a consistency
#   check. It is not unique and never used to find or merge accounts.
# - `user_id` points at Runout's own user, whose UUID never derives from Last.fm data.
class Identity < ApplicationRecord
  LASTFM = "lastfm".freeze

  belongs_to :user

  # { "session_key" => "..." } for Last.fm. Encrypted at rest (non-deterministic).
  serialize :credentials, coder: JSON
  encrypts :credentials

  validates :provider, :uid, presence: true
  validates :uid, uniqueness: { scope: :provider }

  scope :active, -> { where(revoked_at: nil) }

  def session_key
    credentials&.fetch("session_key", nil)
  end
end
