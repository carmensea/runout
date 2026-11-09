class User < ApplicationRecord
  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_one :lastfm_connection, dependent: :destroy
  has_one :lastfm_identity, -> { where(provider: Identity::LASTFM) }, class_name: "Identity"
  has_one :google_identity, -> { where(provider: Identity::GOOGLE) }, class_name: "Identity"
  # Runout's own sign-in (docs/milestone-5-plan.md §2); deleted with the user by the database.
  has_many :webauthn_credentials, dependent: nil
  has_many :recovery_codes, dependent: nil
  has_many :sign_in_links, dependent: nil

  # Listening history. Deleting a user removes these through database cascades (no callbacks), so
  # a large history is deleted in one statement.
  has_many :scrobbles, dependent: nil
  has_many :import_runs, dependent: nil
  has_many :import_windows, dependent: nil
  has_many :scrobble_corrections, dependent: nil
  has_many :scrobble_removals, dependent: nil
  has_many :reconciliation_disputes, dependent: nil
  has_many :review_decisions, dependent: nil
  has_many :listening_sources, dependent: nil # deleted with the user by the database
  has_many :listening_observations, dependent: nil
  has_many :loved_tracks, dependent: nil # deleted with the user by the database
  has_many :memories, dependent: nil # deleted with the user by the database

  # Must match THEMES in src/theme/theme.ts.
  THEMES = %w[original moss cotton-candy midnight-candy verdant].freeze

  # Features an account can see before everyone does (docs/milestone-5-plan.md §4.5 "Rollout").
  # Granted by hand: bin/rails features:grant[user_id,display_name,feature].
  FEATURES = %w[memories].freeze

  NAME_MAX = 80

  validates :display_name, presence: true, length: { maximum: NAME_MAX }
  validates :features, inclusion: { in: FEATURES }
  validates :theme, inclusion: { in: THEMES }, allow_nil: true
  validates :reporting_timezone, inclusion: { in: ->(_) { User.timezones } }

  def self.timezones
    @timezones ||= TZInfo::Timezone.all_identifiers.to_set
  end

  def feature?(name) = features.include?(name.to_s)

  # Has a way to sign in again: a passkey, Google, or Last.fm. An invited account without one is
  # unfinished: its invitation stays open and every page is the welcome page.
  def sign_in_method?
    webauthn_credentials.active.exists? || identities.active.where(provider: [ Identity::GOOGLE, Identity::LASTFM ]).exists?
  end

  def self.timezone_or_default(name)
    timezones.include?(name.to_s) ? name.to_s : "UTC"
  end
end
