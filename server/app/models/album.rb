class Album < ApplicationRecord
  include HistoryStorage
  include Mergeable

  belongs_to :artist
  has_many :name_variants, dependent: :nullify

  before_validation { self.normalized_title = CatalogName.normalize(title) }
  validates :title, :normalized_title, presence: true
  validates :mbid, uniqueness: true, allow_nil: true
end
