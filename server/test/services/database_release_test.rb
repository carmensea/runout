require "test_helper"

class DatabaseReleaseTest < ActiveSupport::TestCase
  FakeConnection = Struct.new(:tables)

  test "an empty database is a first deploy" do
    assert DatabaseRelease.check!(FakeConnection.new([]))
  end

  test "a migrated database is not" do
    assert_not DatabaseRelease.check!(FakeConnection.new(%w[schema_migrations scrobbles]))
  end

  test "tables without schema_migrations stop the release, so no schema loads over them" do
    assert_raises(DatabaseRelease::UnsafeState) { DatabaseRelease.check!(FakeConnection.new(%w[scrobbles])) }
  end
end
