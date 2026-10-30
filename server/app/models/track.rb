class Track < ApplicationRecord
  include HistoryStorage

  belongs_to :artist
  belongs_to :merged_into, class_name: "Track", optional: true
  has_many :merged_from, class_name: "Track", foreign_key: :merged_into_id, inverse_of: :merged_into, dependent: :restrict_with_exception
  has_many :name_variants, dependent: :nullify

  before_validation { self.normalized_title = CatalogName.normalize(title) }
  validates :title, :normalized_title, presence: true
  validates :mbid, uniqueness: true, allow_nil: true

  # The entity this one now stands for: itself, or the end of its merged_into chain.
  def resolved
    seen = [ self ]
    seen << seen.last.merged_into while seen.last.merged_into && !seen.include?(seen.last.merged_into)
    seen.last
  end
end
