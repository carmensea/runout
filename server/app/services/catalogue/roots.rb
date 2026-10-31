module Catalogue
  # Merge chains in SQL (Mergeable): a subquery of (id, root_id) for every merged entity of a table
  # whose chain ends at an unmerged entity, however many merges long. Entities not merged, and any on
  # or leading into a cycle, have no row: they stand for themselves, as Mergeable#resolved says.
  #
  #   LEFT JOIN #{Catalogue::Roots.sql("artists")} ar_root ON ar_root.id = ar.id
  #   ... COALESCE(ar_root.root_id, ar.id)
  module Roots
    TABLES = %w[artists albums tracks].freeze

    def self.sql(table)
      raise ArgumentError, "not a catalogue table: #{table}" unless TABLES.include?(table)

      <<~SQL.squish
        (WITH RECURSIVE walk(id, cur, path) AS (
           SELECT id, merged_into_id, ARRAY[id] FROM #{table} WHERE merged_into_id IS NOT NULL
           UNION ALL
           SELECT w.id, e.merged_into_id, w.path || e.id
             FROM walk w JOIN #{table} e ON e.id = w.cur
            WHERE e.merged_into_id IS NOT NULL AND e.id <> ALL (w.path)
         )
         SELECT w.id, w.cur AS root_id FROM walk w JOIN #{table} r ON r.id = w.cur AND r.merged_into_id IS NULL)
      SQL
    end
  end
end
