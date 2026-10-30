class Album < ApplicationRecord
  include HistoryStorage

  belongs_to :artist
  belongs_to :merged_into, class_name: "Album", optional: true
  has_many :name_variants, dependent: :nullify

  before_validation { self.normalized_title = CatalogName.normalize(title) }
  validates :title, :normalized_title, presence: true
  validates :mbid, uniqueness: true, allow_nil: true
end
