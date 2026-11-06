# The other three check constraints in the form that changes across a pg_restore (the same gotcha
# as 20261106000002; production's definitions were checked on 2026-11-06): the provider and source
# lists from 20261105000002. Same values, same behaviour; forward-only in production.
class RestoreSafeProviderConstraints < ActiveRecord::Migration[8.1]
  CONSTRAINTS = {
    [ :listening_sources, :listening_sources_provider, :provider ] => %w[spotify listenbrainz],
    [ :listening_observations, :listening_observations_provider, :provider ] => %w[spotify listenbrainz],
    [ :scrobbles, :scrobbles_source, :source ] => %w[lastfm spotify listenbrainz]
  }.freeze

  def up
    CONSTRAINTS.each { |(table, name, column), values| swap table, name, "#{column}::text IN (#{quoted(values)})" }
  end

  def down
    CONSTRAINTS.each { |(table, name, column), values| swap table, name, "#{column} IN (#{quoted(values)})" }
  end

  private

  def swap(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end

  def quoted(values) = values.map { |v| "'#{v}'" }.join(", ")
end
