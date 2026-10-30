# A staged play from one fetch. `position` is its order within the second as Last.fm returned it;
# `occurrence` numbers identical plays (same second, same strings) so legitimate duplicates are
# kept apart rather than collapsed. Staging is deleted once the window commits.
class ImportWindowRow < ApplicationRecord
  include HistoryStorage

  belongs_to :import_window_fetch

  validates :played_at, :variant_hash, presence: true
  validates :position, :occurrence, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
