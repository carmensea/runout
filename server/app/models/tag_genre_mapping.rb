# A provider genre or tag name counting towards a genre, with the share of its weight that goes there.
class TagGenreMapping < ApplicationRecord
  ORIGINS = %w[seed manual musicbrainz].freeze

  belongs_to :genre

  validates :tag, presence: true
  validates :weight, numericality: { greater_than: 0, less_than_or_equal_to: 1 }
  validates :origin, inclusion: { in: ORIGINS }

  # Provider names are compared in lower case with single spaces (MusicBrainz writes genres so).
  def self.normalize(name) = name.to_s.unicode_normalize(:nfkc).downcase.strip.gsub(/\s+/, " ")
end
