require "net/http"
require "time"

module Lastfm
  # Minimal Last.fm web service client (https://www.last.fm/api).
  #
  # Signing follows https://www.last.fm/api/webauth: parameters sorted by name, each name and
  # value concatenated without separators, the shared secret appended, and the MD5 hex digest
  # sent as api_sig. `format` and `callback` are excluded from the signature.
  #
  # Reliability (Milestone 2, Stage 2.2):
  # - Every request reserves a slot from a pacer, normally the database-backed global
  #   Lastfm::RequestPacer.
  # - Transient failures (network errors, timeouts, HTTP 5xx, unparseable bodies, Last.fm errors 8,
  #   11 and 16) are retried up to `max_attempts`, with exponential backoff and full jitter.
  # - Rate limiting (HTTP 429, error 29) also triggers a global cool-down. Retry-After is honoured,
  #   and a wait longer than `max_retry_after` raises instead of blocking.
  # - Permanent errors (bad token, invalid key, bad parameters, malformed data) are never retried.
  # - auth.getSession is never retried: its token is single-use, so a retry after a timeout could
  #   fail confusingly or consume the token twice.
  # - Credentials never appear in error messages or #inspect.
  class Client
    API_URL = URI("https://ws.audioscrobbler.com/2.0/")
    AUTH_URL = "https://www.last.fm/api/auth/".freeze
    USER_AGENT = "Runout/0.1 (personal listening archive)".freeze
    UNSIGNED_PARAMS = %w[format callback].freeze

    # Background imports: one quick retry and short waits, so job retries (scheduled, not blocking)
    # handle anything longer. See docs/milestone-2-plan.md §7.3, "Combined retry budget".
    BACKGROUND_OPTIONS = { max_attempts: 2, max_retry_after: 10.0 }.freeze

    REDACTED = "[REDACTED]".freeze
    SECRET_PARAMS = %w[api_key api_sig sk token].freeze

    def initialize(api_key:, shared_secret:, open_timeout: 5, read_timeout: 15, pacer: nil, max_attempts: 4,
                   base_delay: 1.0, max_delay: 60.0, max_retry_after: 300.0,
                   sleeper: ->(seconds) { sleep(seconds) }, random: Random.new)
      @api_key = api_key
      @shared_secret = shared_secret
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @pacer = pacer
      @max_attempts = max_attempts
      @base_delay = base_delay
      @max_delay = max_delay
      @max_retry_after = max_retry_after
      @sleeper = sleeper
      @random = random
      @http_requests = 0
    end

    # HTTP requests actually sent, retries included. Used to enforce per-window request budgets.
    attr_reader :http_requests

    def inspect
      "#<#{self.class.name} api_key=#{REDACTED} shared_secret=#{REDACTED} pacer=#{@pacer.class.name}>"
    end
    alias to_s inspect

    # Where to send the browser so the user can authorise Runout.
    def authorization_url(callback_url)
      "#{AUTH_URL}?#{URI.encode_www_form(api_key: @api_key, cb: callback_url)}"
    end

    # Exchanges a single-use auth token (valid for 60 minutes) for a session key.
    def get_session(token)
      body = call("auth.getSession", { token: token }, signed: true, retryable: false)
      session = body.fetch("session") { raise Error::BadResponse, "auth.getSession response has no session" }
      {
        username: session.fetch("name"),
        session_key: session.fetch("key")
      }
    rescue KeyError => e
      raise Error::BadResponse, "auth.getSession response is missing #{e.key}"
    end

    # Profile of the user who authorised the session key. No `user` parameter is sent, so the
    # answer describes the session's own account rather than whoever currently owns a name.
    #
    # Last.fm's live responses (JSON and XML, checked 2026-10-29) carry no numeric account id,
    # despite the documented sample. What they do carry is returned here; deciding whether that is
    # enough to identify the account is Lastfm::SignIn's job.
    def user_info(session_key:)
      parse_user(call("user.getInfo", { sk: session_key }, signed: true))
    end

    # Public profile for a username (unsigned). Used only by the operator's relink task as a
    # consistency check; it proves nothing about who controls the account.
    def public_user_info(username)
      parse_user(call("user.getInfo", { user: username }))
    end

    # One page of a user's scrobbles, newest first. Read-only: returns a RecentTracksPage and stores
    # nothing. `from` and `to` are Times (sent as Unix seconds); see docs/lastfm-api-findings.md for
    # the verified boundary behaviour. Pass `session_key:` to sign the request (private profiles).
    def recent_tracks(username:, page: 1, limit: 200, from: nil, to: nil, extended: false, session_key: nil)
      raise ArgumentError, "limit must be 1..200" unless (1..200).cover?(limit)

      params = { user: username, page: page, limit: limit }
      params[:from] = from.to_i if from
      params[:to] = to.to_i if to
      params[:extended] = 1 if extended
      params[:sk] = session_key if session_key
      RecentTracksPage.parse(call("user.getRecentTracks", params, signed: session_key.present?))
    end

    def signature(params)
      payload = params
        .reject { |k, _| UNSIGNED_PARAMS.include?(k.to_s) }
        .sort_by { |k, _| k.to_s }
        .map { |k, v| "#{k}#{v}" }
        .join
      Digest::MD5.hexdigest("#{payload}#{@shared_secret}".encode(Encoding::UTF_8))
    end

    # One page of a user's loved tracks, newest first. Read-only: returns a LovedTracksPage and stores
    # nothing. Public data; no session key needed.
    def loved_tracks(username:, page: 1, limit: 1000)
      raise ArgumentError, "limit must be 1..1000" unless (1..1000).cover?(limit)

      LovedTracksPage.parse(call("user.getLovedTracks", { user: username, page: page, limit: limit }))
    end

    private

    def parse_user(body)
      user = body.fetch("user") { raise Error::BadResponse, "user.getInfo response has no user" }
      username = user["name"].to_s
      raise Error::BadResponse, "user.getInfo response has no name" if username.empty?

      registered = user.dig("registered", "unixtime") || user.dig("registered", "#text")
      {
        username: username,
        profile_url: user["url"].presence,
        registered_at: registered.to_s.match?(/\A\d+\z/) ? Time.at(registered.to_i).utc : nil,
        playcount: user["playcount"].to_s.match?(/\A\d+\z/) ? user["playcount"].to_i : nil
      }
    end

    def call(method, params, signed: false, retryable: true)
      query = { method: method, api_key: @api_key }.merge(params).transform_keys(&:to_s)
      query["api_sig"] = signature(query) if signed
      query["format"] = "json"
      secrets = [ @api_key, @shared_secret, *query.values_at(*SECRET_PARAMS) ].compact.map(&:to_s).reject(&:empty?)

      uri = API_URL.dup
      uri.query = URI.encode_www_form(query)

      attempt = 0
      begin
        attempt += 1
        @pacer&.reserve!
        parse(request(uri), secrets)
      rescue Error::Temporary => e
        raise unless retryable && attempt < @max_attempts

        delay = retry_delay(e, attempt)
        raise if delay.nil?

        @pacer&.cool_down!(delay) if e.is_a?(Error::RateLimited)
        @sleeper.call(delay)
        retry
      end
    end

    # Seconds to wait before the next attempt, or nil when the server asked for longer than we will
    # wait (the caller, typically a job, decides when to try again).
    def retry_delay(error, attempt)
      if error.retry_after
        return nil if error.retry_after > @max_retry_after

        return error.retry_after
      end

      cap = [ @max_delay, @base_delay * (2**(attempt - 1)) * (error.is_a?(Error::RateLimited) ? 4 : 1) ].min
      @random.rand * cap # full jitter
    end

    def request(uri)
      @http_requests += 1
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        req = Net::HTTP::Get.new(uri)
        req["User-Agent"] = USER_AGENT
        req["Accept"] = "application/json"
        http.request(req)
      end
    rescue Timeout::Error, Net::HTTPBadResponse, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      # Only the class name: network exception messages can include the request URL and its query.
      raise Error::Temporary, "Last.fm could not be reached (#{e.class.name})"
    end

    def parse(response, secrets)
      status = response.code.to_i
      retry_after = parse_retry_after(response["Retry-After"])
      body = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        nil
      end

      if body.is_a?(Hash) && body["error"]
        code = body["error"].to_i
        klass = Error::BY_CODE.fetch(code, Error::RequestRejected)
        message = redact("Last.fm error #{code}: #{body['message']}", secrets)
        raise klass.new(message, code: code, http_status: status, retry_after: retry_after)
      end
      raise Error::RateLimited.new("Last.fm returned HTTP 429", http_status: status, retry_after: retry_after) if status == 429
      raise Error::Temporary.new("Last.fm returned HTTP #{status}", http_status: status, retry_after: retry_after) if status >= 500
      raise Error::RequestRejected.new("Last.fm returned HTTP #{status}", http_status: status) unless (200..299).cover?(status)
      raise Error::Unparseable.new("Last.fm returned HTTP #{status} with a body that is not valid JSON", http_status: status) unless body.is_a?(Hash)

      body
    end

    # Retry-After is either delay-seconds or an HTTP-date (RFC 9110 §10.2.3).
    def parse_retry_after(value)
      return nil if value.blank?
      return Float(value) if value.strip.match?(/\A\d+(\.\d+)?\z/)

      [ Time.httpdate(value.strip) - Time.now, 0.0 ].max
    rescue ArgumentError
      nil
    end

    def redact(text, secrets)
      secrets.reduce(text.to_s) { |out, secret| out.gsub(secret, REDACTED) }
    end
  end
end
