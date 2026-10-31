# One play. Identity within a user is (played_at, seq); see the scrobbles migration. `source` is the
# provider whose report created it; other providers' reports of the same play are observations.
class Scrobble < ApplicationRecord
  include HistoryStorage

  SOURCES = %w[lastfm spotify].freeze

  belongs_to :user
  belongs_to :name_variant
  belongs_to :first_seen_fetch, class_name: "ImportWindowFetch", optional: true
  has_many :corrections, class_name: "ScrobbleCorrection", dependent: :destroy
  has_many :removals, class_name: "ScrobbleRemoval", dependent: :destroy
  has_many :observations, class_name: "ListeningObservation", dependent: :restrict_with_exception

  validates :played_at, presence: true
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  validates :source, inclusion: { in: SOURCES }

  scope :present, -> { where(removed_at: nil) }
  # The plays Last.fm import, reconciliation and counts work on: never another source's.
  scope :from_lastfm, -> { where(source: "lastfm") }
  # Half-open [from, to), like Last.fm's own ranges. Served by the identity index.
  scope :played_between, ->(from, to) { where(played_at: from...to) }
end
