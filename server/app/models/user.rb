class User < ApplicationRecord
  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_one :lastfm_connection, dependent: :destroy
  has_one :lastfm_identity, -> { where(provider: Identity::LASTFM) }, class_name: "Identity"

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

  validates :display_name, presence: true
  validates :reporting_timezone, inclusion: { in: ->(_) { User.timezones } }

  def self.timezones
    @timezones ||= TZInfo::Timezone.all_identifiers.to_set
  end

  def self.timezone_or_default(name)
    timezones.include?(name.to_s) ? name.to_s : "UTC"
  end
end
