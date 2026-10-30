module Lastfm
  # Base error. `code` is Last.fm's error code when the API returned one; `retry_after` is the
  # server's requested wait in seconds (from a Retry-After header), when it sent one.
  #
  # Messages never contain credentials: the client builds them from codes and statuses and
  # redacts anything echoed back by Last.fm (Client#redact).
  class Error < StandardError
    attr_reader :code, :http_status, :retry_after

    def initialize(message = nil, code: nil, http_status: nil, retry_after: nil)
      super(message)
      @code = code
      @http_status = http_status
      @retry_after = retry_after
    end

    # Whether retrying later may succeed (used by import jobs in Milestone 2).
    def retryable? = false

    # Network failures, timeouts, HTTP 5xx and Last.fm's temporary errors (8, 11, 16).
    class Temporary < Error
      def retryable? = true
    end

    # Error 29 or HTTP 429: rate limit exceeded.
    class RateLimited < Temporary; end

    # A successful-looking response whose body isn't valid JSON (truncated, an HTML error page).
    # Usually transient, so retryable; BadResponse is for valid JSON missing required data.
    class Unparseable < Temporary; end

    # Errors 4, 14, 15: the sign-in token is invalid, was not authorised, or expired.
    class TokenRejected < Error; end

    # Error 9: the user revoked access or the session key is otherwise invalid.
    class InvalidSessionKey < Error; end

    # Errors 10 and 26: the API key is invalid or suspended. Nothing works until it is fixed.
    class ApiKeyRejected < Error; end

    # Any other API error (for example 6, invalid parameters).
    class RequestRejected < Error; end

    # Valid JSON that lacks what the call requires (for example, no user). Permanent.
    class BadResponse < Error; end

    # Credentials are not configured on this server.
    class NotConfigured < Error; end

    BY_CODE = {
      4 => TokenRejected, 14 => TokenRejected, 15 => TokenRejected,
      8 => Temporary, 11 => Temporary, 16 => Temporary,
      29 => RateLimited,
      9 => InvalidSessionKey,
      10 => ApiKeyRejected, 26 => ApiKeyRejected
    }.freeze
  end
end
