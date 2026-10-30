class Artist < ApplicationRecord
  include HistoryStorage

  belongs_to :merged_into, class_name: "Artist", optional: true
  has_many :albums, dependent: :restrict_with_exception
  has_many :tracks, dependent: :restrict_with_exception
  has_many :name_variants, dependent: :nullify

  before_validation { self.normalized_name = CatalogName.normalize(name) }
  validates :name, :normalized_name, presence: true
  validates :mbid, uniqueness: true, allow_nil: true
end
