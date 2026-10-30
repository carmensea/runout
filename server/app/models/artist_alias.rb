# An alternative name that identifies exactly one artist, from a curated source: a person's
# decision (`manual`) or MusicBrainz data (`musicbrainz`, a later milestone). A name shared by
# chance never becomes an alias on its own.
class ArtistAlias < ApplicationRecord
  include HistoryStorage

  SOURCES = %w[manual musicbrainz].freeze

  belongs_to :artist

  before_validation { self.normalized_name = CatalogName.normalize(name) }
  validates :name, :normalized_name, presence: true
  validates :source, inclusion: { in: SOURCES }
end
