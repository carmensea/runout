# Audit trail: every review decision, and every automatic change to a review item, with who made
# it (a person, or `reconciliation`) and the evidence. Rows are only ever added.
class ReviewDecision < ApplicationRecord
  include HistoryStorage

  belongs_to :user
  belongs_to :decided_by, class_name: "User", optional: true

  validates :subject_type, :subject_id, :action, :source, presence: true

  def readonly? = persisted?

  def self.record!(subject, action, source:, by: nil, **details)
    create!(user_id: subject.user_id, subject_type: subject.class.name, subject_id: subject.id, action: action.to_s,
            source: source.to_s, decided_by: by, details: details)
  end
end
