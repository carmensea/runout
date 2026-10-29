class User < ApplicationRecord
  has_many :identities, dependent: :destroy
  has_many :sessions, dependent: :destroy
  has_one :lastfm_connection, dependent: :destroy
  has_one :lastfm_identity, -> { where(provider: Identity::LASTFM) }, class_name: "Identity"

  validates :display_name, presence: true
  validates :reporting_timezone, inclusion: { in: ->(_) { User.timezones } }

  def self.timezones
    @timezones ||= TZInfo::Timezone.all_identifiers.to_set
  end

  def self.timezone_or_default(name)
    timezones.include?(name.to_s) ? name.to_s : "UTC"
  end
end
