module Lastfm
  # Completes Last.fm web authentication: exchanges the callback token for a session key, verifies
  # who signed in, and finds or creates the local user under Lastfm::AccountPolicy.
  #
  # Identity rules (docs/backend-plan.md §2):
  # - Runout's user ID is its own UUID and never derives from Last.fm data.
  # - The identity's lookup key (`identities.uid`) is the normalised Last.fm username, which only
  #   an explicit relink can change. It is not treated as permanent.
  # - The account's registration time is recorded and must match on every later sign-in. It is a
  #   consistency check only: never a lookup key, never grounds for merging accounts.
  # - Anything uncertain stops sign-in. Nothing is merged, transferred or guessed.
  class SignIn
    # auth.getSession and user.getInfo disagree about who signed in.
    class IdentityMismatch < Error; end
    # The authenticated account is not one this deployment is configured for.
    class AccountNotAllowed < Error; end
    # Last.fm did not return what is needed to verify the account (no registration time).
    class IdentityUnverifiable < Error; end
    # The username is linked, but its registration time differs from the one recorded: it may now
    # belong to a different Last.fm account.
    class IdentityChanged < Error; end
    # Single-account mode: an account is already linked under a different username (for example
    # after a rename). Needs an explicit relink.
    class RelinkRequired < Error; end

    Result = Data.define(:user, :identity, :created)

    def initialize(client:)
      @client = client
    end

    def call(token:, timezone: nil)
      session = @client.get_session(token)
      profile = @client.user_info(session_key: session[:session_key])
      unless profile[:username].casecmp?(session[:username])
        raise IdentityMismatch, "auth.getSession and user.getInfo returned different usernames"
      end
      raise AccountNotAllowed, "this Last.fm account is not configured for this deployment" unless AccountPolicy.allowed?(profile[:username])
      raise IdentityUnverifiable, "user.getInfo returned no registration time" if profile[:registered_at].nil?

      attempts = 0
      begin
        attempts += 1
        link(profile, session, timezone)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        # Two first sign-ins at once: one loses the unique index (or the uniqueness validation, if
        # the other had already committed). Retrying finds the identity the other request created.
        raise unless attempts < 2 && duplicate_identity?(e)

        retry
      end
    end

    private

    def link(profile, session, timezone)
      uid = AccountPolicy.normalize(profile[:username])

      # A savepoint, so a unique-index violation can be retried even inside an outer transaction.
      ActiveRecord::Base.transaction(requires_new: true) do
        identity = Identity.lock.find_by(provider: Identity::LASTFM, uid: uid)
        created = identity.nil?

        if identity
          verify_unchanged!(identity, profile)
        else
          refuse_second_account! if AccountPolicy.single_account?
          identity = create_account(uid, profile, timezone)
        end

        identity.update!(
          username: profile[:username],
          profile_url: profile[:profile_url],
          registered_at: profile[:registered_at],
          credentials: { "session_key" => session[:session_key] },
          last_authenticated_at: Time.current,
          revoked_at: nil
        )
        Result.new(user: identity.user, identity: identity, created: created)
      end
    end

    # A missing stored value counts as a mismatch: uncertainty stops sign-in.
    def verify_unchanged!(identity, profile)
      return if identity.registered_at && identity.registered_at.to_i == profile[:registered_at].to_i

      raise IdentityChanged, "registration time does not match the linked account"
    end

    def refuse_second_account!
      return unless Identity.where(provider: Identity::LASTFM).exists?

      raise RelinkRequired, "a different Last.fm username is already linked"
    end

    def duplicate_identity?(error)
      return true if error.is_a?(ActiveRecord::RecordNotUnique)

      error.record.is_a?(Identity) && error.record.errors.added?(:uid, :taken, value: error.record.uid)
    end

    def create_account(uid, profile, timezone)
      user = User.create!(
        display_name: profile[:username],
        reporting_timezone: User.timezone_or_default(timezone)
      )
      identity = user.identities.create!(provider: Identity::LASTFM, uid: uid, username: profile[:username],
                                         registered_at: profile[:registered_at])
      user.create_lastfm_connection!(identity: identity)
      identity
    end
  end
end
