# A cover inferred for one user's Overview album or track from ListenBrainz's MBID mapping of that
# user's listens (Metadata::InferredArtwork). Never a catalogue fact: other users don't see it, and
# nothing about the album, track or variant changes.
class InferredArtwork < ApplicationRecord
  STATUSES = %w[pending ok none mismatch failed].freeze

  belongs_to :user

  validates :status, inclusion: { in: STATUSES }
  validates :subject_key, :release_id, presence: true

  scope :due, ->(now = Time.current) {
    where(status: %w[pending failed]).where("next_attempt_at IS NULL OR next_attempt_at <= ?", now).order(observations: :desc, id: :asc)
  }
end
