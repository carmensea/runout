# A matching question for a person (docs/milestone-2-plan.md §6.4):
# - `ambiguous`: the variant fits several entities, so it is linked to none of them;
# - `possible_match`: the variant is linked to a name-only entity that may be the same as an
#   identified one (with a MusicBrainz ID) of the same name.
# Re-matching closes reviews that no longer apply (`superseded`) and never reopens a dismissed one
# for the same candidates.
class CatalogueReview < ApplicationRecord
  include HistoryStorage

  LEVELS = %w[artist album track].freeze
  KINDS = %w[ambiguous possible_match].freeze
  STATES = %w[open resolved dismissed superseded].freeze

  belongs_to :name_variant
  belongs_to :decided_by, class_name: "User", optional: true

  validates :level, inclusion: { in: LEVELS }
  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }

  scope :open, -> { where(state: "open") }

  def candidates = Catalogue::Matcher::MODELS.fetch(level).where(id: candidate_ids)
end
