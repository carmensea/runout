# What the container may do to the primary database at start. db:prepare loads the schema, dropping
# same-named tables, whenever schema_migrations is missing. So a partly restored archive must stop
# the release instead of reaching it.
module DatabaseRelease
  class UnsafeState < StandardError; end

  module_function

  # Returns whether the database is empty, so the caller knows this is a first deploy.
  def check!(connection = ActiveRecord::Base.connection)
    tables = connection.tables
    return true if tables.empty?
    return false if tables.include?("schema_migrations")

    raise UnsafeState, "The primary database has #{tables.size} tables but no schema_migrations. " \
                       "Refusing to load the schema over them; check the restore."
  rescue ActiveRecord::NoDatabaseError
    true
  end
end
