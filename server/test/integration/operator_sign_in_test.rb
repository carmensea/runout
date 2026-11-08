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

  # Every way of changing the account, opening another way in, or outliving the hour, as the owner's
  # brief requires: the operator reads, and that is all.
  test "an operator session reads, cannot change anything or obtain a way in, and ends after an hour" do
    @user.update!(features: [ "memories" ])
    _, other_token = Session.start!(user: @user, ip_address: "203.0.113.9", user_agent: "the person's phone")
    recovery = SignInLink.issue!(@user)
    spotify = ListeningSource.create!(user: @user, provider: "spotify", external_account_id: "dana-spotify", display_name: "Dana", state: "connected", connected_at: Time.current)
    before = { users: User.count, sessions: Session.count, name: @user.display_name }

    travel_to Time.utc(2026, 11, 8, 12, 0) do
      out, = capture_io { @task.invoke(@user.id, "Dana") }
      get out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}]
      assert_redirected_to "/overview"
      session = Session.where(operator: true).sole
      assert_equal Time.utc(2026, 11, 8, 13, 0), session.expires_at, "an hour, not thirty days"

      # Reads work, and say what this is.
      get "/api/connection"
      assert_response :ok
      assert_equal({ "expiresAt" => "2026-11-08T13:00:00Z" }, json["operator"])
      get "/api/sessions"
      assert_equal [ true, false ], json["sessions"].map { |s| s["operator"] }.sort_by { |o| o ? 0 : 1 }
      get "/api/listening-sources"
      assert_response :ok
      get "/api/passkeys"
      assert_response :ok
      get "/api/memories"
      assert_response :ok

      # Writes and ways in are refused, whatever the verb.
      refused = [
        [ :post, "/api/passkeys/options", {} ], [ :post, "/api/passkeys", { id: "x", rawId: "x", type: "public-key", response: {} } ],
        [ :delete, "/api/passkeys/1", {} ], [ :post, "/api/recovery-codes", {} ],
        [ :patch, "/api/account", { displayName: "Taken over" } ], [ :delete, "/api/account", { confirm_name: "Dana" } ],
        [ :delete, "/api/sessions/#{Session.find_by_token(other_token).id}", {} ],
        [ :post, "/api/import", {} ], [ :post, "/api/import/pause", {} ], [ :post, "/api/sync/refresh", {} ], [ :post, "/api/sync/pause", {} ],
        [ :post, "/api/reviews/removal/1/approve", {} ],
        [ :post, "/api/listening-sources/spotify/disconnect", {} ], [ :post, "/api/listening-sources/spotify/pause", {} ],
        [ :post, "/api/listening-sources/listenbrainz", { token: "t" } ], [ :post, "/api/listening-sources/listenbrainz/disconnect", {} ],
        [ :post, "/api/listening-sources/reviews/1/link", {} ],
        [ :post, "/api/memories", { song: "t1", body: "x" } ], [ :patch, "/api/memories/1", { body: "x" } ], [ :delete, "/api/memories/1", {} ],
        [ :get, "/api/auth/spotify", {} ], [ :get, "/api/auth/spotify/begin", {} ], [ :get, "/api/auth/spotify/callback", { code: "c", state: "s" } ],
        [ :get, "/api/auth/lastfm", {} ], [ :get, "/api/auth/lastfm/callback", { token: "t" } ],
        [ :get, "/api/auth/link/#{recovery}", {} ],
        [ :post, "/api/auth/passkey/options", {} ], [ :post, "/api/auth/passkey", {} ], [ :post, "/api/auth/recovery", { code: "x" } ]
      ]
      refused.each do |verb, path, body|
        send(verb, path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json"))
        assert_response :forbidden, "#{verb.upcase} #{path}"
        assert_equal "operator_session", json["error"], "#{verb.upcase} #{path}"
      end
      assert_equal 0, WebauthnCredential.count, "no passkey enrolled"
      assert_equal 0, RecoveryCode.count, "no recovery codes made"
      assert_nil SignInLink.find_by(token_digest: Session.digest(recovery)).used_at, "the recovery link is untouched"
      assert_equal before[:users], User.count
      assert_equal before[:name], @user.reload.display_name
      assert_equal "connected", spotify.reload.state
      assert_equal 0, Memory.count
      assert Session.find_by_token(other_token), "the person's own session is untouched"
      assert_equal before[:sessions] + 1, Session.count, "nothing opened besides the operator session"
    end

    # Activity never extends it; at the hour it is gone.
    travel_to Time.utc(2026, 11, 8, 12, 59) do
      get "/api/connection"
      assert_equal "Dana", json["displayName"]
      assert_equal Time.utc(2026, 11, 8, 13, 0), Session.where(operator: true).sole.expires_at
    end
    travel_to Time.utc(2026, 11, 8, 13, 1) do
      get "/api/connection"
      assert_equal "signed_out", json["status"]
      get "/api/sessions"
      assert_response :unauthorized
    end
  end

  test "an operator session can end itself" do
    out, = capture_io { @task.invoke(@user.id, "Dana") }
    get out[%r{http://localhost:5173/api/auth/link/[A-Za-z0-9_-]{43}}]
    delete "/api/session", headers: same_origin_headers
    assert_response :no_content
    assert_equal 0, Session.where(operator: true).count
    get "/api/connection"
    assert_equal "signed_out", json["status"]
  end

  test "a wrong name or id issues nothing" do
    @task.reenable
    assert_raises(SystemExit) { capture_io { @task.invoke(@user.id, "Someone") } }
    @task.reenable
    assert_raises(SystemExit) { capture_io { @task.invoke(SecureRandom.uuid, "Dana") } }
    assert_equal 0, SignInLink.count
  end
end
