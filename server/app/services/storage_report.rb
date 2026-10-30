# Size of everything Runout stores that derives from Last.fm (docs/milestone-2-plan.md §2), to
# compare with whatever Last.fm's terms allow. Read-only.
#
# Later stages add their tables (scrobbles, name variants, staging, catalogue) to LASTFM_TABLES.
module StorageReport
  LASTFM_TABLES = %w[identities lastfm_connections].freeze

  Row = Data.define(:table, :rows, :bytes)

  module_function

  def rows
    connection = ActiveRecord::Base.connection
    LASTFM_TABLES.select { |table| connection.table_exists?(table) }.map do |table|
      quoted = connection.quote(table)
      Row.new(
        table: table,
        rows: connection.select_value("SELECT count(*) FROM #{connection.quote_table_name(table)}").to_i,
        bytes: connection.select_value("SELECT pg_total_relation_size(#{quoted}::regclass)").to_i
      )
    end
  end

  def total_bytes(report = rows)
    report.sum(&:bytes)
  end
end
