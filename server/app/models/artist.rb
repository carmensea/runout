class Artist < ApplicationRecord
  include HistoryStorage

  belongs_to :merged_into, class_name: "Artist", optional: true
  has_many :merged_from, class_name: "Artist", foreign_key: :merged_into_id, inverse_of: :merged_into, dependent: :restrict_with_exception
  has_many :aliases, class_name: "ArtistAlias", dependent: :delete_all
  has_many :albums, dependent: :restrict_with_exception
  has_many :tracks, dependent: :restrict_with_exception
  has_many :name_variants, dependent: :nullify

  before_validation { self.normalized_name = CatalogName.normalize(name) }
  validates :name, :normalized_name, presence: true
  validates :mbid, uniqueness: true, allow_nil: true

  # The entity this one now stands for: itself, or the end of its merged_into chain.
  def resolved
    seen = [ self ]
    seen << seen.last.merged_into while seen.last.merged_into && !seen.include?(seen.last.merged_into)
    seen.last
  end
end
