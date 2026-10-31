# One provider's report of one play (docs/spotify-plan.md §2–3): its own timestamp and what that
# timestamp means, the exact strings (a name variant) and the provider's IDs, and the canonical
# play it attests. Reports are kept as first received; a later report of the same event that
# differs is noted in `later_values`, never applied.
class ListeningObservation < ApplicationRecord
  include HistoryStorage

  LINK_STATES = %w[created linked pending_review].freeze

  belongs_to :user
  belongs_to :listening_source
  belongs_to :name_variant
  belongs_to :scrobble, optional: true

  validates :link_state, inclusion: { in: LINK_STATES }
  validates :source_event_id, :reported_at, :reported_at_raw, :timestamp_kind, presence: true

  scope :pending_review, -> { where(link_state: "pending_review") }
end
