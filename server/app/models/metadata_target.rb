# An entity to enrich, and where its enrichment stands (docs/milestone-4-plan.md §5): queued by
# plays, due at `next_attempt_at`; `not_found` and `invalid` are cached negative results.
class MetadataTarget < ApplicationRecord
  STATUSES = %w[pending ok not_found invalid failed].freeze

  validates :status, inclusion: { in: STATUSES }

  scope :due, ->(now = Time.current) { where(next_attempt_at: ..now).order(priority: :desc, id: :asc) }
end
