module Listenbrainz
  # Errors from the ListenBrainz API. Messages never contain the user's token.
  class Error < StandardError
    attr_reader :status

    def initialize(message = nil, status: nil)
      super(message)
      @status = status
    end

    class Unavailable < Error; end # network failures and 5xx: try again later
    class NotFound < Error; end    # 404: no such ListenBrainz user (renamed or deleted)
    class Rejected < Error; end    # any other refusal

    class RateLimited < Error      # 429: wait at least retry_after seconds
      attr_reader :retry_after

      def initialize(message = nil, retry_after:)
        super(message, status: 429)
        @retry_after = retry_after
      end
    end
  end
end
