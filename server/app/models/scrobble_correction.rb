# A name change for an existing play. Auditable: rows are never deleted, decisions record who and when.
class ScrobbleCorrection < ApplicationRecord
  include HistoryStorage

  STATES = %w[applied pending_review dismissed].freeze

  belongs_to :user
  belongs_to :scrobble
  belongs_to :from_variant, class_name: "NameVariant"
  belongs_to :to_variant, class_name: "NameVariant"
  belongs_to :import_window_fetch, optional: true
  belongs_to :decided_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }
  validates :reason, presence: true

  scope :pending, -> { where(state: "pending_review") }
end
