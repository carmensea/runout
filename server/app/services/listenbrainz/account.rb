module Listenbrainz
  # Connecting a ListenBrainz account to a Runout user (docs/listenbrainz-spotify-feasibility.md §8,
  # token minimisation): the token proves ownership once, through validate-token, and is then
  # discarded. The source keeps the verified username and the binding only; reading listens needs
  # no token. One ListenBrainz account belongs to one Runout user; reconnecting keeps the source
  # and everything recorded from it.
  class Account
    class InvalidToken < StandardError; end
    class AccountTaken < StandardError; end

    def initialize(client: Client.new, clock: -> { Time.current })
      @client = client
      @clock = clock
    end

    def connect!(user:, token:)
      username = @client.validate_token(token.to_s.strip) or raise InvalidToken, "ListenBrainz did not recognise that token"
      ListeningSource.transaction do
        source = ListeningSource.lock.find_by(provider: "listenbrainz", external_account_id: username)
        raise AccountTaken, "this ListenBrainz account is connected to another Runout account" if source && source.user_id != user.id

        source ||= ListeningSource.new(user: user, provider: "listenbrainz", external_account_id: username, connected_at: now)
        source.update!(display_name: username, state: "connected", credentials: nil, scopes: nil, disconnected_at: nil,
                       last_error: nil, last_error_at: nil, next_poll_at: nil, consecutive_failures: 0,
                       connected_at: source.state == "disconnected" ? now : source.connected_at)
        source
      end
    end

    def disconnect!(source)
      source.update!(state: "disconnected", credentials: nil, disconnected_at: now)
    end

    private

    def now = @clock.call
  end
end
