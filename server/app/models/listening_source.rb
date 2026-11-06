# A connected provider account that reports plays (docs/spotify-plan.md §2). Credentials are
# encrypted at rest and never leave the server: the API serialises status, never this record.
class ListeningSource < ApplicationRecord
  PROVIDERS = %w[spotify listenbrainz].freeze
  STATES = %w[connected needs_reauth disconnected].freeze

  belongs_to :user
  has_many :observations, class_name: "ListeningObservation", dependent: :restrict_with_exception
  has_many :polls, class_name: "ListeningPoll", dependent: :delete_all
  has_many :gaps, class_name: "ListeningGap", dependent: :delete_all

  # { "access_token", "refresh_token", "expires_at" (epoch seconds) }. Non-deterministic encryption.
  serialize :credentials, coder: JSON
  encrypts :credentials

  validates :provider, inclusion: { in: PROVIDERS }
  validates :state, inclusion: { in: STATES }
  validates :external_account_id, presence: true

  scope :spotify, -> { where(provider: "spotify") }
  scope :active, -> { where(state: "connected") }

  def paused? = paused_at.present?
  def connected? = state == "connected"

  # Never in logs or inspect output.
  def inspect = "#<ListeningSource id=#{id.inspect} provider=#{provider.inspect} state=#{state.inspect}>"
end
