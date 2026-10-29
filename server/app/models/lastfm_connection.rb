class LastfmConnection < ApplicationRecord
  HISTORY_STATES = %w[not_started importing imported failed].freeze

  belongs_to :user
  belongs_to :identity

  validates :history_state, inclusion: { in: HISTORY_STATES }
end
