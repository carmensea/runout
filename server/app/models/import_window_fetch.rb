# One attempt at fetching a window: its outcome, counts and error details, kept for audit and for
# the two-consecutive-reads removal rule.
class ImportWindowFetch < ApplicationRecord
  include HistoryStorage

  OUTCOMES = %w[in_progress validated mismatch failed].freeze

  belongs_to :import_window
  has_many :rows, class_name: "ImportWindowRow", dependent: :delete_all

  validates :outcome, inclusion: { in: OUTCOMES }
  validates :attempt, numericality: { only_integer: true, greater_than: 0 }
end
