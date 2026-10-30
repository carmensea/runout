class ImportRun < ApplicationRecord
  include HistoryStorage

  KINDS = %w[full sync catch_up reconcile].freeze
  STATES = %w[planning running completed failed cancelled].freeze

  belongs_to :user
  has_many :import_windows, dependent: :nullify

  validates :kind, inclusion: { in: KINDS }
  validates :state, inclusion: { in: STATES }
end
