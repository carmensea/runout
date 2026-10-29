require "test_helper"

class SessionTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(display_name: "listener", reporting_timezone: "UTC")
  end

  test "stores only a digest of the token" do
    session, token = Session.start!(user: @user, ip_address: "127.0.0.1", user_agent: "test")
    assert_not_equal token, session.token_digest
    assert_equal Session.digest(token), session.token_digest
    assert_equal session, Session.find_by_token(token)
  end

  test "tokens are long and random" do
    _, a = Session.start!(user: @user, ip_address: nil, user_agent: nil)
    _, b = Session.start!(user: @user, ip_address: nil, user_agent: nil)
    assert_not_equal a, b
    assert_operator a.length, :>=, 43
  end

  test "expired sessions are not found" do
    session, token = Session.start!(user: @user, ip_address: nil, user_agent: nil)
    session.update_columns(expires_at: 1.minute.ago)
    assert_nil Session.find_by_token(token)
  end

  test "unknown or blank tokens find nothing" do
    assert_nil Session.find_by_token("not-a-token")
    assert_nil Session.find_by_token(nil)
  end

  test "activity extends expiry at most once per refresh interval" do
    session, = Session.start!(user: @user, ip_address: nil, user_agent: nil)
    assert_not session.touch_activity!

    travel 2.hours do
      assert session.touch_activity!
      assert_in_delta (Time.current + Session::LIFETIME).to_i, session.reload.expires_at.to_i, 1
    end
  end

  test "activity never extends a session past its absolute lifetime" do
    session, token = Session.start!(user: @user, ip_address: nil, user_agent: nil)

    travel(Session::ABSOLUTE_LIFETIME - 1.day) do
      session.touch_activity!
      assert_in_delta (session.created_at + Session::ABSOLUTE_LIFETIME).to_i, session.reload.expires_at.to_i, 1
      assert_equal session, Session.find_by_token(token)
    end

    travel(Session::ABSOLUTE_LIFETIME + 1.minute) do
      session.update_columns(expires_at: 1.day.from_now) # even a forged expiry cannot outlive the cap
      assert_nil Session.find_by_token(token)
    end
  end
end
