# A second listening provider for the multi-user beta (docs/multi-user-plan.md §1.4, decision 4):
# the constraints learn the value now so the ListenBrainz source later needs no change to live
# tables. Nothing writes `listenbrainz` yet: ListeningStorage.enabled?("listenbrainz") is false
# until its step 0 device test passes and a flag exists. Additive; reversible while no row uses it.
class AllowListenbrainzProvider < ActiveRecord::Migration[8.1]
  PROVIDERS = %w[spotify listenbrainz].freeze
  SOURCES = %w[lastfm spotify listenbrainz].freeze

  def up
    swap :listening_sources, :listening_sources_provider, "provider IN (#{quoted(PROVIDERS)})"
    swap :listening_observations, :listening_observations_provider, "provider IN (#{quoted(PROVIDERS)})"
    swap :scrobbles, :scrobbles_source, "source IN (#{quoted(SOURCES)})"
  end

  def down
    swap :listening_sources, :listening_sources_provider, "provider = 'spotify'"
    swap :listening_observations, :listening_observations_provider, "provider = 'spotify'"
    swap :scrobbles, :scrobbles_source, "source IN ('lastfm', 'spotify')"
  end

  private

  def swap(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end

  def quoted(values) = values.map { |v| "'#{v}'" }.join(", ")
end
