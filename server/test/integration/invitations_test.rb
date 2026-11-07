require "test_helper"
require "webauthn/fake_client"
require "rake"

# Invitation-only registration (docs/multi-user-plan.md §3, PR 2): the operator's task creates the
# account and a single-use 24-hour link; opening it signs the person in to enrol a passkey and get
# recovery codes; the link is scoped to that enrolment and dies with it. No request can register.
class InvitationsTest < ActionDispatch::IntegrationTest
  ORIGIN = "http://localhost:5173".freeze

  setup do
    @flag = Rails.configuration.x.passkeys_enabled
    Rails.configuration.x.passkeys_enabled = "true"
    Rails.application.load_tasks unless Rake::Task.task_defined?("auth:invite_link")
    @task = Rake::Task["auth:invite_link"]
    @task.reenable
  end
  teardown { Rails.configuration.x.passkeys_enabled = @flag }

  def json = response.parsed_body

  def post_json(path, body = {})
    post path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
  end

  def invite!(name = "Dana", tz = "America/Los_Angeles")
    out, = capture_io { @task.invoke(name, tz) }
    @task.reenable
    out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}] or flunk("no link in #{out.inspect}")
  end

  test "the task creates the account with its timezone and a 24-hour link; the person enrols and the link dies" do
    link = invite!
    assert_equal 1, User.count
    dana = User.sole
    assert_equal [ "Dana", "America/Los_Angeles" ], [ dana.display_name, dana.reporting_timezone ]
    assert_equal "invitation", SignInLink.sole.kind
    assert_in_delta 24.hours.from_now, SignInLink.sole.expires_at, 5

    get link
    assert_redirected_to "/welcome"
    assert_predicate session_cookie, :present?
    get "/api/session"
    assert_equal({ "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false }, json["methods"])
    get "/api/connection"
    assert_equal "none", json["status"]
    get "/api/overview"
    assert_response :conflict, "an empty archive, nobody else's"

    # Not spent by being opened: another browser (a phone after a laptop, a person after a link
    # preview) opens it again until a passkey exists.
    delete "/api/session", headers: same_origin_headers
    get link
    assert_redirected_to "/welcome"
    assert_predicate session_cookie, :present?

    # Enrolment through the normal passkey flow; the first passkey brings the codes.
    client = WebAuthn::FakeClient.new(ORIGIN)
    post_json "/api/passkeys/options"
    credential = client.create(challenge: json["challenge"], user_verified: true)
    post_json "/api/passkeys", { credential: credential, nickname: "Phone" }
    assert_response :created
    assert_equal 10, json["recoveryCodes"].size
    get "/api/session"
    assert_equal({ "passkeys" => 1, "recoveryCodes" => 10, "lastfm" => false }, json["methods"])

    # Enrolled: the opened link and a fresh invitation are both dead, the link is scoped to enrolment.
    fresh = SignInLink.issue!(dana, kind: "invitation")
    delete "/api/session", headers: same_origin_headers
    get link
    assert_redirected_to "/overview?auth_error=link_invalid"
    get "/api/auth/link/#{fresh}"
    assert_redirected_to "/overview?auth_error=link_invalid"
    assert_nil SignInLink.find_by(token_digest: Session.digest(fresh)).used_at

    # The recovery link still works for an enrolled account and lands on the Overview.
    recovery = SignInLink.issue!(dana)
    get "/api/auth/link/#{recovery}"
    assert_redirected_to "/overview"
  end

  test "an invitation expires after 24 hours" do
    link = invite!
    travel 25.hours do
      get link
      assert_redirected_to "/overview?auth_error=link_invalid"
    end
  end

  test "running the task again for an unfinished invitation reuses the empty account" do
    invite!("Dana", "Europe/London")
    link = invite!("Dana", "America/Los_Angeles")
    assert_equal 1, User.count, "no second empty account"
    assert_equal "America/Los_Angeles", User.sole.reporting_timezone
    assert_equal 2, SignInLink.count
    get link
    assert_redirected_to "/welcome"
  end

  test "an enrolled account with the same name is never reused" do
    invite!
    get SignInLink.sole.then { |_| invite! } # second link for the unfinished account
    WebauthnCredential.create!(user: User.sole, external_id: "cred", public_key: "pk")
    invite!
    assert_equal 2, User.count, "a new account, because Dana's first one is real now"
  end

  test "the task refuses a bad timezone, an empty name, and the flag being off" do
    assert_raises(SystemExit) { capture_io { @task.invoke("Dana", "Mars/Olympus") } }
    @task.reenable
    assert_raises(SystemExit) { capture_io { @task.invoke("", "Europe/London") } }
    @task.reenable
    Rails.configuration.x.passkeys_enabled = "false"
    assert_raises(SystemExit) { capture_io { @task.invoke("Dana", "Europe/London") } }
    assert_equal 0, User.count
    assert_equal 0, SignInLink.count
  end

  test "nothing registers without the task: the invited account is isolated from the owner's" do
    sign_in_via_lastfm(username: "listener")
    owner = User.sole
    cookies.delete(Authentication::COOKIE_NAME) # another browser from here on; the owner stays signed in
    link = invite!
    get link
    assert_redirected_to "/welcome"
    get "/api/loved-tracks"
    assert_response :conflict
    get "/api/sessions"
    assert_equal 1, json["sessions"].size
    assert_equal 2, User.count
    assert_equal 1, Session.where(user: owner).count, "the owner's browser session is untouched"
  end

  test "a chat app's link preview neither signs in nor spends the invitation" do
    link = invite!
    get link, headers: { "User-Agent" => "Mozilla/5.0 (compatible; Discordbot/2.0; +https://discordapp.com)" }
    assert_redirected_to "/overview"
    assert_predicate session_cookie, :blank?
    assert_nil SignInLink.sole.used_at
    get link
    assert_redirected_to "/welcome"
  end

  test "an open invitation, even one already opened, is revoked by id and name without touching anything else" do
    link = invite!
    dana = User.sole
    get link
    assert_redirected_to "/welcome"
    delete "/api/session", headers: same_origin_headers
    task = Rake::Task["auth:revoke_invitation"]
    assert_raises(SystemExit) { capture_io { task.invoke(dana.id, "someone else") } }
    task.reenable
    assert_raises(SystemExit) { capture_io { task.invoke(SecureRandom.uuid, "Dana") } }
    task.reenable
    out, = capture_io { task.invoke(dana.id, "Dana") }
    assert_match(/Revoked 1 open invitation link/, out)
    assert_match(/auth:remove_account\[#{dana.id},Dana,DELETE #{dana.id}\]/, out)
    assert User.exists?(dana.id)
    get link
    assert_redirected_to "/overview?auth_error=link_invalid"
  end

  test "removing an invited account needs its id, its name and the exact confirmation; the owner's account is refused" do
    sign_in_via_lastfm(username: "listener")
    owner = User.sole
    cookies.delete(Authentication::COOKIE_NAME)
    link = invite!
    get link
    dana = User.find_by!(display_name: "Dana")
    task = Rake::Task["auth:remove_account"]

    assert_raises(SystemExit) { capture_io { task.invoke(dana.id, "Dana", "yes") } }
    task.reenable
    assert_raises(SystemExit) { capture_io { task.invoke(dana.id, "Dana", "DELETE #{owner.id}") } }
    task.reenable
    assert_raises(SystemExit) { capture_io { task.invoke(dana.id, "Other", "DELETE #{dana.id}") } }
    task.reenable
    assert User.exists?(dana.id), "nothing deleted without the exact confirmation"
    assert_raises(SystemExit) { capture_io { task.invoke(owner.id, "listener", "DELETE #{owner.id}") } }
    task.reenable
    assert User.exists?(owner.id), "an account with Last.fm is never removed by the operator"

    out, = capture_io { task.invoke(dana.id, "Dana", "DELETE #{dana.id}") }
    assert_match(/Removed Dana/, out)
    assert_not User.exists?(dana.id)
    assert_equal 0, Session.where(user_id: dana.id).count
    assert User.exists?(owner.id)
    assert_equal 1, Session.where(user: owner).count
  end
end
