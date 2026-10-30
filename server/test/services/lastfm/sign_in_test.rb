require "test_helper"

class Lastfm::SignInTest < ActiveSupport::TestCase
  setup do
    @service = Lastfm::SignIn.new(client: Lastfm::Client.new(api_key: "test-api-key", shared_secret: "test-shared-secret"))
  end

  test "creates a user, an identity keyed by the normalised username, and a connection" do
    stub_get_session(username: "Listener", key: "sk-secret-value")
    stub_user_info(username: "Listener", registered: 1199145600)

    result = @service.call(token: "tok", timezone: "Europe/London")

    assert result.created
    assert_equal "listener", result.identity.uid
    assert_equal "Listener", result.identity.username
    assert_equal Time.at(1199145600).utc, result.identity.registered_at
    assert_equal "sk-secret-value", result.identity.session_key
    assert_equal "Europe/London", result.user.reporting_timezone
    assert_equal "not_started", result.user.lastfm_connection.history_state
    assert_match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/, result.user.id, "Runout's user ID is its own UUID")
  end

  test "stores the session key encrypted" do
    stub_get_session(username: "listener", key: "sk-secret-value")
    stub_user_info(username: "listener")
    identity = @service.call(token: "tok").identity

    raw = Identity.connection.select_value("SELECT credentials FROM identities WHERE id = #{identity.id}")
    assert_not_includes raw, "sk-secret-value"
    assert_equal "sk-secret-value", identity.reload.session_key
  end

  test "signing in again reaches the same user and refreshes the session key" do
    stub_get_session(username: "listener", key: "sk-1")
    stub_user_info(username: "listener")
    first = @service.call(token: "tok-1")

    WebMock.reset!
    stub_get_session(username: "LISTENER", key: "sk-2")
    stub_user_info(username: "LISTENER")
    assert_no_difference -> { User.count } do
      second = @service.call(token: "tok-2")
      assert_not second.created
      assert_equal first.user.id, second.user.id
      assert_equal "sk-2", second.identity.session_key
    end
  end

  test "refuses an account that is not configured for this deployment" do
    stub_get_session(username: "stranger")
    stub_user_info(username: "stranger")
    assert_raises(Lastfm::SignIn::AccountNotAllowed) { @service.call(token: "tok") }
    assert_equal 0, User.count
  end

  test "a renamed account is refused until it is relinked: no second user, nothing moved" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener", registered: 1199145600)
    original = @service.call(token: "tok-1")

    # The operator allows the new name, but has not relinked yet.
    allow_lastfm_accounts("newname")
    WebMock.reset!
    stub_get_session(username: "newname")
    stub_user_info(username: "newname", registered: 1199145600) # same registration time: still not merged

    assert_no_difference [ "User.count", "Identity.count" ] do
      assert_raises(Lastfm::SignIn::RelinkRequired) { @service.call(token: "tok-2") }
    end
    assert_equal "listener", original.identity.reload.uid
  end

  test "a linked username whose registration time changed is refused (it may be a different account)" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener", registered: 1199145600)
    identity = @service.call(token: "tok-1").identity

    WebMock.reset!
    stub_get_session(username: "listener", key: "sk-other")
    stub_user_info(username: "listener", registered: 1500000000)

    assert_raises(Lastfm::SignIn::IdentityChanged) { @service.call(token: "tok-2") }
    assert_equal Time.at(1199145600).utc, identity.reload.registered_at
    assert_not_equal "sk-other", identity.session_key, "the stored session key is untouched"
  end

  test "refuses when Last.fm returns no registration time" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener", registered: nil)
    assert_raises(Lastfm::SignIn::IdentityUnverifiable) { @service.call(token: "tok") }
    assert_equal 0, User.count
  end

  test "refuses when getSession and getInfo disagree" do
    stub_get_session(username: "listener")
    stub_user_info(username: "someone-else")
    assert_raises(Lastfm::SignIn::IdentityMismatch) { @service.call(token: "tok") }
    assert_equal 0, User.count
  end

  test "multi-account mode gives each configured account its own user" do
    allow_lastfm_accounts("alice", "bob")
    stub_get_session(username: "alice")
    stub_user_info(username: "alice", registered: 1199145600)
    alice = @service.call(token: "tok-1")

    WebMock.reset!
    stub_get_session(username: "bob")
    stub_user_info(username: "bob", registered: 1199145600) # same second: still separate users
    bob = @service.call(token: "tok-2")

    assert_not_equal alice.user.id, bob.user.id
    assert_equal 2, User.count
  end

  test "clears a previous revocation when the user signs in again" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener")
    identity = @service.call(token: "tok").identity
    identity.update!(revoked_at: Time.current)

    assert_nil @service.call(token: "tok-2").identity.reload.revoked_at
  end

  test "falls back to UTC for an unknown timezone" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener")
    assert_equal "UTC", @service.call(token: "tok", timezone: "Mars/Olympus").user.reporting_timezone
  end

  test "two first sign-ins for the same account at once end up as one user" do
    stub_get_session(username: "listener")
    stub_user_info(username: "listener")

    # Simulate a concurrent request that creates the identity between our lookup and our insert.
    original = @service.method(:create_account)
    raced = false
    @service.define_singleton_method(:create_account) do |uid, profile, timezone|
      unless raced
        raced = true
        Identity.transaction(requires_new: true) { original.call(uid, profile, timezone) }
      end
      original.call(uid, profile, timezone)
    end

    result = @service.call(token: "tok")
    assert_equal 1, User.count
    assert_equal 1, Identity.count
    assert_equal "listener", result.identity.uid
  end
end
