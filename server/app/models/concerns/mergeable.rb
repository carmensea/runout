# Catalogue entities a person can merge (Catalogue::Decisions.merge!): `merged_into` points at the
# entity this one is the same as. Merges chain (A → B, later B → C), and every chain is followed to
# its end, here and in SQL (Catalogue::Roots), so A, B and C count as one entity: C.
#
# Pointers are never rewritten when a chain grows: each records the decision a person made.
# A cycle (A → B → A) is refused when saved. Should one exist anyway, every entity on or leading
# into it stands for itself, here and in SQL alike: nothing is lost or counted twice.
module Mergeable
  extend ActiveSupport::Concern

  included do
    belongs_to :merged_into, class_name: name, optional: true
    has_many :merged_from, class_name: name, foreign_key: :merged_into_id, inverse_of: :merged_into, dependent: :restrict_with_exception
    belongs_to :inference, class_name: "CatalogueInference", optional: true # set when an inference made the merge, not a person

    validate :merge_chain_ends, if: :merged_into_id_changed?
  end

  # The entity this one now stands for: the end of its merged_into chain, or itself.
  def resolved
    chain = merge_chain
    chain.last.merged_into_id ? self : chain.last
  end

  private

  # This entity and those it is merged into, in order, stopping before any repeat.
  def merge_chain
    chain = [ self ]
    while (next_entity = chain.last.merged_into) && chain.none? { |e| e.id == next_entity.id }
      chain << next_entity
    end
    chain
  end

  def merge_chain_ends
    return if merged_into_id.nil?
    return errors.add(:merged_into, "can't be the entity itself") if merged_into_id == id

    seen = [ id ]
    current = self.class.find_by(id: merged_into_id)
    while current&.merged_into_id
      return errors.add(:merged_into, "would make a cycle of merges") if seen.include?(current.merged_into_id)

      seen << current.id
      current = self.class.find_by(id: current.merged_into_id)
    end
  end
end
