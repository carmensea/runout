module Lastfm
  # Completes Last.fm web authentication: exchanges the callback token for a session key,
  # identifies the account by its numeric Last.fm ID, and finds or creates the local user.
  class SignIn
    # getSession and getInfo disagreed about who signed in.
    class IdentityMismatch < Error; end

    Result = Data.define(:user, :identity, :created)

    def initialize(client:)
      @client = client
    end

    def call(token:, timezone: nil)
      session = @client.get_session(token)
      profile = @client.user_info(session_key: session[:session_key])
      unless profile[:username].casecmp?(session[:username])
        raise IdentityMismatch, "auth.getSession returned #{session[:username]} but user.getInfo returned #{profile[:username]}"
      end

      attempts = 0
      begin
        attempts += 1
        link(profile, session, timezone)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Another request created this account first: caught by the unique index if both inserts
        # overlapped, or by the uniqueness validation if the other one had already committed.
        # Retrying finds the existing identity.
        raise unless attempts < 2 && duplicate_identity?(e)

        retry
      end
    end

    private

    def link(profile, session, timezone)
      # A savepoint, so a unique-index violation can be retried even inside an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        identity = Identity.lock.find_by(provider: Identity::LASTFM, uid: profile[:id])
        created = identity.nil?
        identity ||= create_account(profile, timezone)
        identity.update!(
          username: profile[:username],
          profile_url: profile[:profile_url],
          registered_at: profile[:registered_at] || identity.registered_at,
          credentials: { "session_key" => session[:session_key] },
          last_authenticated_at: Time.current,
          revoked_at: nil
        )
        Result.new(user: identity.user, identity: identity, created: created)
      end
    end

    def duplicate_identity?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      error.record.is_a?(Identity) && error.record.errors.added?(:uid, :taken, value: error.record.uid)
    end

    def create_account(profile, timezone)
      user = User.create!(
        display_name: profile[:username],
        reporting_timezone: User.timezone_or_default(timezone)
      )
      identity = user.identities.create!(provider: Identity::LASTFM, uid: profile[:id], username: profile[:username])
      user.create_lastfm_connection!(identity: identity)
      identity
    end
  end
end
