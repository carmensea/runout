module Spotify
  # Errors from Spotify's accounts service and Web API. Messages never contain tokens or secrets.
  class Error < StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    class Unauthorized < Error; end            # 401: the access token is no longer accepted
    class Forbidden < Error; end               # 403: missing scope, or the account isn't allowed to use this app
    class InvalidGrant < Error; end            # the refresh token or code was refused: connect again
    class Unavailable < Error; end             # network failures and 5xx: try again later
    class Rejected < Error; end                # any other refusal

    class RateLimited < Error                  # 429: wait at least retry_after seconds
      attr_reader :retry_after, :reason

      def initialize(message = nil, retry_after:, reason: nil)
        super(message, status: 429)
        @retry_after = retry_after
        @reason = reason
      end
    end

    # 429 with "reason": "QUOTA_EXCEEDED" (July 2026): the developer account's Development Mode
    # quota is used up, shared by all its apps. Not a burst: retrying soon can't help.
    class QuotaExceeded < RateLimited; end
  end
end
