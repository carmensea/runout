# One play. Identity within a user is (played_at, seq); see the scrobbles migration.
class Scrobble < ApplicationRecord
  include HistoryStorage

  belongs_to :user
  belongs_to :name_variant
  belongs_to :first_seen_fetch, class_name: "ImportWindowFetch", optional: true
  has_many :corrections, class_name: "ScrobbleCorrection", dependent: :destroy
  has_many :removals, class_name: "ScrobbleRemoval", dependent: :destroy

  validates :played_at, presence: true
  validates :seq, numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :present, -> { where(removed_at: nil) }
  # Half-open [from, to), like Last.fm's own ranges. Served by the identity index.
  scope :played_between, ->(from, to) { where(played_at: from...to) }
end
