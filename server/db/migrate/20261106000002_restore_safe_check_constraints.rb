# Three check constraints written `column IN (...)` on string columns come back from a pg_restore
# with a different definition, so the backup job's schema comparison fails (docs/railway-deployment.md
# §7, "Schema gotcha"; it did on 2026-11-06). The `column::text IN (...)` form survives a restore
# unchanged. Same allowed values, same behaviour; forward-only in production (the down restores the
# earlier spelling for the disposable test database only).
class RestoreSafeCheckConstraints < ActiveRecord::Migration[8.1]
  CONSTRAINTS = {
    [ :sign_in_links, :sign_in_links_kind, :kind ] => %w[recovery invitation],
    [ :listening_sources, :listening_sources_backfill_state, :backfill_state ] => %w[running done],
    [ :listening_polls, :listening_polls_trigger, :trigger ] => %w[schedule manual task backfill]
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
