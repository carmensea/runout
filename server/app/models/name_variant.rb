require "digest"

# The exact strings Last.fm sent for a play, stored once and never modified. Catalogue links
# (artist, album, track) can be added or replaced later without touching scrobbles.
class NameVariant < ApplicationRecord
  include HistoryStorage

  MATCH_METHODS = %w[mbid normalized_name manual].freeze # legacy summary column; see the per-level *_match columns
  # How each link (artist, album, track) was made. Linked: `mbid`, `alias`, `name` (a name-only
  # entity), `manual`, and for artists `inferred` (an identified artist found by name,
  # Catalogue::ArtistInference). Not linked: `ambiguous`, `unmatched`, and for albums `none` (no
  # album sent).
  LINKED_MATCHES = %w[mbid alias name manual].freeze
  MATCHES = { artist: LINKED_MATCHES + %w[inferred ambiguous unmatched], album: LINKED_MATCHES + %w[ambiguous unmatched none],
              track: LINKED_MATCHES + %w[ambiguous unmatched] }.freeze
  IDENTITY_FIELDS = %i[artist_name artist_mbid track_name track_mbid album_name album_mbid].freeze

  belongs_to :artist, optional: true
  belongs_to :album, optional: true
  belongs_to :track, optional: true
  has_many :scrobbles, dependent: :restrict_with_exception
  has_many :catalogue_reviews, dependent: :delete_all

  validates :variant_hash, presence: true
  validates :match_method, inclusion: { in: MATCH_METHODS }, allow_nil: true
  MATCHES.each { |level, values| validates :"#{level}_match", inclusion: { in: values }, allow_nil: true }
  validate :identity_unchanged, on: :update

  # SHA-256 over the exact strings. JSON encoding keeps field boundaries unambiguous, and nil (no
  # MBID) stays distinct from an empty string. No trimming or case changes.
  def self.hash_for(fields)
    Digest::SHA256.digest(JSON.generate(IDENTITY_FIELDS.map { |key| fields[key] }))
  end

  # Finds or creates the variant for these exact strings. Safe under concurrency (unique index).
  def self.for!(**fields)
    attributes = IDENTITY_FIELDS.index_with { |key| fields[key] }
    attributes[:album_name] ||= ""
    create_with(attributes).create_or_find_by!(variant_hash: hash_for(attributes))
  end

  private

  def identity_unchanged
    changed = (IDENTITY_FIELDS + [ :variant_hash ]).select { |field| attribute_changed?(field) }
    errors.add(:base, "name variant strings are immutable (changed: #{changed.join(', ')})") if changed.any?
  end
end
