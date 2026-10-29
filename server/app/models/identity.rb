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
