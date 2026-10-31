module Spotify
  # A user's Spotify connection (docs/spotify-plan.md §8): connecting with an authorisation code,
  # keeping the access token fresh, and disconnecting. Credentials live encrypted on the
  # ListeningSource and never leave this module.
  #
  # Refreshes run under a row lock on the source, so two workers never spend the same refresh
  # token: when Spotify rotates it, the second worker finds the new one already stored. A refused
  # refresh token (`invalid_grant`) marks the source `needs_reauth`; nothing retries it.
  class Account
    class AccountTaken < StandardError; end      # that Spotify account is connected to another Runout user
    class InsufficientScope < StandardError; end # the person declined a scope Runout needs
    class NotConnected < StandardError; end      # disconnected, or must connect again

    EARLY = 120 # seconds: refresh this long before the access token expires

    def initialize(client: Client.new, clock: -> { Time.current })
      @client = client
      @clock = clock
    end

    attr_reader :client

    # Exchanges the code, reads the account, and stores the connection. The same Spotify account
    # reconnecting keeps its source (and history); another user's account is refused.
    def connect!(user:, code:)
      tokens = @client.exchange_code(code)
      missing = Config::SCOPES - tokens.scope.split
      raise InsufficientScope, "Spotify didn't grant #{missing.join(', ')}" if missing.any?

      profile = @client.me(tokens.access_token)
      account_id = profile.fetch("id").to_s
      ListeningSource.transaction do
        source = ListeningSource.lock.find_by(provider: "spotify", external_account_id: account_id)
        raise AccountTaken, "this Spotify account is connected to another Runout account" if source && source.user_id != user.id

        source ||= ListeningSource.new(user: user, provider: "spotify", external_account_id: account_id, connected_at: now)
        source.update!(display_name: profile["display_name"].presence || account_id, state: "connected", scopes: tokens.scope,
                       credentials: credentials(tokens), disconnected_at: nil, last_error: nil, last_error_at: nil,
                       next_poll_at: nil, consecutive_failures: 0,
                       connected_at: source.state == "disconnected" ? now : source.connected_at)
        source
      end
    end

    # Yields a valid access token. Refreshes when it is about to expire, and once more if Spotify
    # answers 401 anyway.
    def with_token(source)
      token = fresh_token(source)
      begin
        yield token
      rescue Error::Unauthorized
        yield fresh_token(source, force: true)
      end
    end

    def disconnect!(source)
      source.update!(state: "disconnected", credentials: nil, disconnected_at: now)
    end

    private

    def now = @clock.call

    def credentials(tokens, previous_refresh: nil)
      { "access_token" => tokens.access_token, "refresh_token" => tokens.refresh_token || previous_refresh,
        "expires_at" => now.to_i + tokens.expires_in }
    end

    # The refused-refresh state is recorded after the locking transaction, so raising doesn't roll
    # it back.
    def fresh_token(source, force: false)
      refused = nil
      token = ListeningSource.transaction do
        source.lock!
        raise NotConnected, "Spotify is #{source.state.tr('_', ' ')}" unless source.connected? && source.credentials

        stored = source.credentials
        if force || stored["expires_at"].to_i - EARLY <= now.to_i
          refresh!(source, stored)
        else
          stored["access_token"]
        end
      rescue Error::InvalidGrant => e
        refused = e
        nil
      end
      return token unless refused

      source.update!(state: "needs_reauth", credentials: nil, last_error: refused.message, last_error_at: now)
      raise NotConnected, "Spotify needs to be connected again"
    end

    # Inside fresh_token's transaction, with the source locked.
    def refresh!(source, stored)
      tokens = @client.refresh(stored.fetch("refresh_token"))
      source.update!(credentials: credentials(tokens, previous_refresh: stored["refresh_token"]), scopes: tokens.scope.presence || source.scopes)
      tokens.access_token
    end
  end
end
