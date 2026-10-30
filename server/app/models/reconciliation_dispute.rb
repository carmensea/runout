# A second where a later validated snapshot and the stored plays differ on both sides
# (docs/milestone-2-plan.md §4.4). Without a stable play ID from Last.fm, such a change can't be
# told apart from deletions plus new plays, so nothing in the second changes until a person
# decides (HistoryImport::Review). The evidence stays here: the stored plays involved, and the
# fetched plays as immutable name variants (one entry per play, duplicates included).
class ReconciliationDispute < ApplicationRecord
  include HistoryStorage

  STATES = %w[open resolved dismissed superseded].freeze

  belongs_to :user
  belongs_to :import_window, optional: true
  belongs_to :first_seen_fetch, class_name: "ImportWindowFetch"
  belongs_to :last_seen_fetch, class_name: "ImportWindowFetch"
  belongs_to :decided_by, class_name: "User", optional: true

  validates :state, inclusion: { in: STATES }

  scope :open, -> { where(state: "open") }

  def self.evidence_key(stored_ids, proposed_variant_ids)
    Digest::SHA256.hexdigest(JSON.generate([ stored_ids.sort, proposed_variant_ids.sort ]))
  end

  def stored_scrobbles = Scrobble.where(id: stored_scrobble_ids).includes(:name_variant).order(:seq)
  def proposed_variants = proposed_variant_ids.map { |id| NameVariant.find(id) }
end
