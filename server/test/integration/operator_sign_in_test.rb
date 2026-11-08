require "test_helper"
require "rake"

# The operator's sign-in-as link (bin/rails auth:sign_in_as): single use, opens an operator session,
# which the person sees in their list of signed-in browsers (docs/railway-deployment.md).
class OperatorSignInTest < ActionDispatch::IntegrationTest
  setup do
    @flag = Rails.configuration.x.passkeys_enabled
    Rails.configuration.x.passkeys_enabled = "true"
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:sign_in_as")
    @task = Rake::Task["auth:sign_in_as"]
    @task.reenable
    @user = User.create!(display_name: "Dana", reporting_timezone: "UTC")
  end
  teardown { Rails.configuration.x.passkeys_enabled = @flag }

  def json = response.parsed_body

  test "the link signs the browser in as the person with an operator session, once" do
    out, = capture_io { @task.invoke(@user.id, "Dana") }
    link = out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}] or flunk("no link in #{out.inspect}")
    assert_match(/placeholder words/, out)
    assert_equal "operator", SignInLink.sole.kind

    get link
    assert_redirected_to "/overview"
    assert_equal true, Session.sole.operator
    get "/api/sessions"
    assert_equal [ true ], json["sessions"].map { |s| s["operator"] }
    get "/api/connection"
    assert_equal "Dana", json["displayName"]

    delete "/api/session", headers: same_origin_headers
    get link
    assert_redirected_to "/overview?auth_error=link_invalid"
  end

  test "a wrong name or id issues nothing" do
    @task.reenable
    assert_raises(SystemExit) { capture_io { @task.invoke(@user.id, "Someone") } }
    @task.reenable
    assert_raises(SystemExit) { capture_io { @task.invoke(SecureRandom.uuid, "Dana") } }
    assert_equal 0, SignInLink.count
  end
end
