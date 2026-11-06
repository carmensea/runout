# One poll of a listening source: what it fetched and recorded, or why it stopped
# (docs/spotify-plan.md §10).
class ListeningPoll < ApplicationRecord
  TRIGGERS = %w[schedule manual task backfill].freeze
  OUTCOMES = %w[ok rate_limited quota_exceeded unauthorized forbidden needs_reauth unavailable failed].freeze

  belongs_to :listening_source

  validates :trigger, inclusion: { in: TRIGGERS }
end
