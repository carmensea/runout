# One import of a user's history (docs/milestone-2-plan.md §7). At most one active run per user
# (a partial unique index). `job_token` names the single job chain allowed to act for the run:
# pausing, cancelling or a watchdog restart replace it, and any job holding an old token stops.
class ImportRun < ApplicationRecord
  include HistoryStorage

  KINDS = %w[full sync catch_up reconcile].freeze
  STATES = %w[planning running paused needs_review completed failed cancelled].freeze
  ACTIVE_STATES = %w[planning running paused needs_review].freeze
  # States in which jobs do work; `paused` and `needs_review` wait for a person.
  WORKING_STATES = %w[planning running].freeze

  belongs_to :user
  has_many :import_windows, dependent: :nullify

  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }

  scope :active, -> { where(state: ACTIVE_STATES) }
  scope :working, -> { where(state: WORKING_STATES) }

  def working? = WORKING_STATES.include?(state)
end
