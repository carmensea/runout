# A genre in Runout's taxonomy: broad, or a subgenre of one broad genre (docs/milestone-4-plan.md §3).
class Genre < ApplicationRecord
  LEVELS = %w[broad sub].freeze
  ORIGINS = %w[seed manual].freeze

  belongs_to :parent, class_name: "Genre", optional: true
  has_many :subgenres, class_name: "Genre", foreign_key: :parent_id, inverse_of: :parent, dependent: :restrict_with_exception
  has_many :mappings, class_name: "TagGenreMapping", dependent: :delete_all

  validates :slug, :name, presence: true
  validates :level, inclusion: { in: LEVELS }
  validates :origin, inclusion: { in: ORIGINS }

  scope :broad, -> { where(level: "broad") }
end
