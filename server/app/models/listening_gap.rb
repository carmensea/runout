# An interval a listening source may no longer be able to return (docs/spotify-plan.md §10): plays
# in it may be missing. Never filled with made-up plays.
class ListeningGap < ApplicationRecord
  belongs_to :listening_source
  belongs_to :listening_poll, optional: true

  scope :open, -> { where(resolved_at: nil) }
end
