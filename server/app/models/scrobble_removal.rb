# A play Last.fm stopped returning. Never applied automatically: it needs two agreeing verified
# fetches to reach pending_review, and an approval to set scrobbles.removed_at.
class ScrobbleRemoval < ApplicationRecord
  include HistoryStorage

  STATES = %w[observed pending_review approved dismissed restored].freeze

  belongs_to :user
  belongs_to :scrobble
  belongs_to :first_missing_fetch, class_name: "ImportWindowFetch"
  belongs_to :confirming_fetch, class_name: "ImportWindowFetch", optional: true
  belongs_to :decided_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }

  scope :unresolved, -> { where(state: %w[observed pending_review]) }
end
