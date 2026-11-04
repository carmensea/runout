# A song a person loves (docs/loved-songs.md). Owned by Runout: Last.fm's loved list is one source
# of rows, favourites made here (`runout`) are another, and a Last.fm refresh never touches `runout`
# or `manual` rows. The song is a name variant: exactly what the source said, matched to the
# catalogue by the usual rules, so hearts and play counts follow the same identity as every play.
# Separate from scrobbles: loving a song is not a play. `loved_at` is when it was loved, never when it
# was played.
class LovedTrack < ApplicationRecord
  include HistoryStorage

  SOURCES = %w[lastfm runout].freeze

  belongs_to :user
  belongs_to :name_variant

  validates :source, inclusion: { in: SOURCES }
  validates :loved_at, presence: true

  scope :current, -> { where(unloved_at: nil) }
  scope :lastfm, -> { where(source: "lastfm") }
end
