require "test_helper"
require "rake"

class LastfmRelinkTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "lastfm:relink" }
    @user = User.create!(display_name: "listener")
    @identity = @user.identities.create!(provider: Identity::LASTFM, uid: "listener", username: "listener",
                                         registered_at: Time.at(1199145600).utc, credentials: { "session_key" => "sk" })
    @user.create_lastfm_connection!(identity: @identity)
  end

  test "relinks after a rename when the registration time matches, and requires a fresh sign-in" do
    allow_lastfm_accounts("newname")
    stub_user_info(username: "NewName", registered: 1199145600)

    run_task("listener", "newname")

    @identity.reload
    assert_equal "newname", @identity.uid
    assert_equal "NewName", @identity.username
    assert_nil @identity.session_key
    assert @identity.revoked_at, "the relinked account must sign in again"
    assert_equal 1, User.count
    assert_equal @user.id, @identity.user_id
  end

  test "refuses when the registration time differs" do
    allow_lastfm_accounts("newname")
    stub_user_info(username: "newname", registered: 1500000000)

    assert_raises(SystemExit) { run_task("listener", "newname") }
    assert_equal "listener", @identity.reload.uid
  end

  test "refuses when the new username is not allowed" do
    assert_raises(SystemExit) { run_task("listener", "newname") }
    assert_equal "listener", @identity.reload.uid
  end

  test "refuses when the old username is not linked" do
    allow_lastfm_accounts("newname")
    assert_raises(SystemExit) { run_task("nobody", "newname") }
    assert_equal "listener", @identity.reload.uid
  end

  private

  def run_task(old_name, new_name)
    task = Rake::Task["lastfm:relink"]
    task.reenable
    capture_io { task.invoke(old_name, new_name) }
  end
end
