# One poll of a listening source: what it fetched and recorded, or why it stopped
# (docs/spotify-plan.md §10).
class ListeningPoll < ApplicationRecord
  TRIGGERS = %w[schedule manual task].freeze

  belongs_to :listening_source

  validates :trigger, inclusion: { in: TRIGGERS }
end
