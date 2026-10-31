# An artist link inferred from a name (Catalogue::ArtistInference), with its evidence. `applied`
# while in force; `reverted` once undone, after which the same inference is never made again.
class CatalogueInference < ApplicationRecord
  include HistoryStorage

  belongs_to :into, class_name: "Artist"
  belongs_to :from, class_name: "Artist", optional: true
  has_many :resolved_reviews, class_name: "CatalogueReview", foreign_key: :inference_id, inverse_of: :inference,
                              dependent: :restrict_with_exception

  validates :level, inclusion: { in: %w[artist] }
  validates :state, inclusion: { in: %w[applied reverted] }

  scope :applied, -> { where(state: "applied") }
  scope :reverted, -> { where(state: "reverted") }
end
