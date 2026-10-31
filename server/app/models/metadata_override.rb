# The owner's correction of a provider value (`genres`, `artist_type` or `gender`). Wins over the
# provider; enrichment never writes or removes overrides.
#
# `genres` is a list of { "genre" => slug, "weight" => number }, used instead of provider genres.
class MetadataOverride < ApplicationRecord
  FIELDS = %w[genres artist_type gender].freeze

  validates :field, inclusion: { in: FIELDS }
  validate :genres_known, if: -> { field == "genres" }

  private

  def genres_known
    slugs = Array(value).map { |g| g["genre"] }
    unknown = slugs - Genre.where(slug: slugs).pluck(:slug)
    errors.add(:value, "names unknown genres: #{unknown.join(', ')}") if unknown.any?
    errors.add(:value, "needs positive weights") unless Array(value).all? { |g| g["weight"].to_f.positive? }
  end
end
