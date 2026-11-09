module GoogleSignIn
  # Google as a sign-in identity of a Runout account (docs/google-sign-in.md §3). The rules:
  # - An identity is found only by Google's stable subject (`identities.uid`), never by an address.
  # - Signing in never creates an account: a Google account nobody linked signs nobody in.
  # - Linking attaches Google to the signed-in account and to nothing else: a Google account that
  #   belongs to another Runout account is refused, and an account that already has a Google
  #   identity keeps it until its owner unlinks it. Nothing is merged, moved or overwritten.
  # - Unlinking is refused when it would leave the account with no way in.
  module Account
    # The Google account is linked to a different Runout account.
    class Unavailable < StandardError; end
    # This Runout account already has a different Google account linked.
    class AlreadyLinked < StandardError; end
    # Unlinking would leave no usable sign-in method.
    class LastMethod < StandardError; end

    module_function

    # The user this Google account signs in, or nil. Records the sign-in on the identity.
    def sign_in(verified)
      identity = Identity.active.find_by(provider: Identity::GOOGLE, uid: verified.sub) or return nil
      identity.update!(username: verified.email || identity.username, last_authenticated_at: Time.current)
      identity.user
    end

    def link!(user, verified)
      attempts = 0
      begin
        attempts += 1
        ActiveRecord::Base.transaction(requires_new: true) do
          taken = Identity.lock.find_by(provider: Identity::GOOGLE, uid: verified.sub)
          raise Unavailable if taken && taken.user_id != user.id

          own = Identity.lock.find_by(provider: Identity::GOOGLE, user_id: user.id)
          raise AlreadyLinked if own && own.uid != verified.sub

          identity = own || user.identities.new(provider: Identity::GOOGLE, uid: verified.sub)
          identity.update!(username: verified.email, last_authenticated_at: Time.current, revoked_at: nil)
          identity
        end
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        # Two links at once: the loser re-reads and gets the plain answer (Unavailable or its own row).
        raise if attempts >= 2

        retry
      end
    end

    # Removes the identity. `keep`: the session doing it; the account's other sessions end, since a
    # way in was just withdrawn.
    def unlink!(user, keep:)
      identity = user.google_identity or return
      lastfm = user.lastfm_identity
      raise LastMethod unless user.webauthn_credentials.active.exists? || (lastfm.present? && lastfm.revoked_at.nil?)

      ActiveRecord::Base.transaction do
        identity.destroy!
        user.sessions.where.not(id: keep.id).destroy_all
      end
    end
  end
end
