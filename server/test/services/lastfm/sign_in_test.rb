require "test_helper"

class Lastfm::SignInTest < ActiveSupport::TestCase
  setup do
    @service = Lastfm::SignIn.new(client: Lastfm::Client.new(api_key: "test-api-key", shared_secret: "test-shared-secret"))
  end

  test "creates a user, a Last.fm identity keyed by numeric id, and a connection" do
    stub_get_session(username: "listener", key: "sk-secret-value")
    stub_user_info(id: 1001, username: "listener")

    result = @service.call(token: "tok", timezone: "Europe/London")

    assert result.created
    assert_equal "1001", result.identity.uid
    assert_equal "listener", result.identity.username
    assert_equal "sk-secret-value", result.identity.session_key
    assert_equal "Europe/London", result.user.reporting_timezone
    assert_equal "not_started", result.user.lastfm_connection.history_state
  end

  test "stores the session key encrypted" do
    stub_get_session(username: "listener", key: "sk-secret-value")
    stub_user_info(id: 1001, username: "listener")
    identity = @service.call(token: "tok").identity

    raw = Identity.connection.select_value("SELECT credentials FROM identities WHERE id = #{identity.id}")
    assert_not_includes raw, "sk-secret-value"
    assert_equal "sk-secret-value", identity.reload.session_key
  end

  test "a username change keeps the same account, because the numeric id is the identity" do
    stub_get_session(username: "oldname")
    stub_user_info(id: 2002, username: "oldname")
    first = @service.call(token: "tok-1")

    WebMock.reset!
    stub_get_session(username: "newname", key: "sk-2")
    stub_user_info(id: 2002, username: "newname")

    assert_no_difference -> { User.count } do
      assert_no_difference -> { Identity.count } do
        second = @service.call(token: "tok-2")
        assert_not second.created
        assert_equal first.user.id, second.user.id
        assert_equal "newname", second.identity.username
        assert_equal "sk-2", second.identity.session_key
      end
    end
  end

  test "a different account that later uses an old username is a different user" do
    stub_get_session(username: "sharedname")
    stub_user_info(id: 3003, username: "sharedname")
    first = @service.call(token: "tok-1")

    WebMock.reset!
    stub_get_session(username: "sharedname")
    stub_user_info(id: 3004, username: "sharedname")
    second = @service.call(token: "tok-2")

    assert_not_equal first.user.id, second.user.id
  end

  test "clears a previous revocation when the user signs in again" do
    stub_get_session(username: "listener")
    stub_user_info(id: 1001, username: "listener")
    identity = @service.call(token: "tok").identity
    identity.update!(revoked_at: Time.current)

    assert_nil @service.call(token: "tok-2").identity.reload.revoked_at
  end

  test "refuses to sign in when getSession and getInfo disagree" do
    stub_get_session(username: "listener")
    stub_user_info(id: 1001, username: "someone-else")
    assert_raises(Lastfm::SignIn::IdentityMismatch) { @service.call(token: "tok") }
    assert_equal 0, User.count
  end

  test "falls back to UTC for an unknown timezone" do
    stub_get_session(username: "listener")
    stub_user_info(id: 1001, username: "listener")
    assert_equal "UTC", @service.call(token: "tok", timezone: "Mars/Olympus").user.reporting_timezone
  end

  test "two first sign-ins for the same account at once end up as one user" do
    stub_get_session(username: "listener")
    stub_user_info(id: 1001, username: "listener")

    # Simulate a concurrent request that creates the identity between our lookup and our insert.
    original = @service.method(:create_account)
    raced = false
    @service.define_singleton_method(:create_account) do |profile, timezone|
      unless raced
        raced = true
        Identity.transaction(requires_new: true) { original.call(profile, timezone) }
      end
      original.call(profile, timezone)
    end

    result = @service.call(token: "tok")
    assert_equal 1, User.count
    assert_equal 1, Identity.count
    assert_equal "1001", result.identity.uid
  end
end
