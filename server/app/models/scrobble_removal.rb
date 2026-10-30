# A play Last.fm stopped returning. Never applied automatically: it needs two independent validated
# reconciliations (different fetches) to reach pending_review, and an approval to set
# scrobbles.removed_at. `restored`: seen again. `reappeared`: an approved removal that Last.fm
# returns again, open for review.
class ScrobbleRemoval < ApplicationRecord
  include HistoryStorage

  STATES = %w[observed pending_review approved dismissed restored reappeared].freeze
  OPEN_STATES = %w[observed pending_review reappeared].freeze

  belongs_to :user
  belongs_to :scrobble
  belongs_to :first_missing_fetch, class_name: "ImportWindowFetch"
  belongs_to :confirming_fetch, class_name: "ImportWindowFetch", optional: true
  belongs_to :decided_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }

  scope :unresolved, -> { where(state: OPEN_STATES) }
end
