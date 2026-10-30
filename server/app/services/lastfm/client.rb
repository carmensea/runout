require "net/http"

module Lastfm
  # Minimal Last.fm web service client (https://www.last.fm/api).
  #
  # Signing follows https://www.last.fm/api/webauth: parameters sorted by name, each name and
  # value concatenated without separators, the shared secret appended, and the MD5 hex digest
  # sent as api_sig. `format` and `callback` are excluded from the signature.
  class Client
    API_URL = URI("https://ws.audioscrobbler.com/2.0/")
    AUTH_URL = "https://www.last.fm/api/auth/".freeze
    USER_AGENT = "Runout/0.1 (personal listening archive)".freeze
    UNSIGNED_PARAMS = %w[format callback].freeze

    def initialize(api_key:, shared_secret:, open_timeout: 5, read_timeout: 15)
      @api_key = api_key
      @shared_secret = shared_secret
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    # Where to send the browser so the user can authorise Runout.
    def authorization_url(callback_url)
      "#{AUTH_URL}?#{URI.encode_www_form(api_key: @api_key, cb: callback_url)}"
    end

    # Exchanges a single-use auth token (valid for 60 minutes) for a session key.
    def get_session(token)
      body = call("auth.getSession", { token: token }, signed: true)
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

    private

    def parse_user(body)
      user = body.fetch("user") { raise Error::BadResponse, "user.getInfo response has no user" }
      username = user["name"].to_s
      raise Error::BadResponse, "user.getInfo response has no name" if username.empty?

      registered = user.dig("registered", "unixtime") || user.dig("registered", "#text")
      {
        username: username,
        profile_url: user["url"].presence,
        registered_at: registered.to_s.match?(/\A\d+\z/) ? Time.at(registered.to_i).utc : nil
      }
    end

    def call(method, params, signed: false)
      query = { method: method, api_key: @api_key }.merge(params).transform_keys(&:to_s)
      query["api_sig"] = signature(query) if signed
      query["format"] = "json"

      uri = API_URL.dup
      uri.query = URI.encode_www_form(query)
      response = request(uri)
      parse(response)
    end

    def request(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        req = Net::HTTP::Get.new(uri)
        req["User-Agent"] = USER_AGENT
        req["Accept"] = "application/json"
        http.request(req)
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::HTTPBadResponse, SocketError, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error::Temporary, "Last.fm could not be reached (#{e.class.name})"
    end

    def parse(response)
      status = response.code.to_i
      body = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        nil
      end

      if body.is_a?(Hash) && body["error"]
        code = body["error"].to_i
        klass = Error::BY_CODE.fetch(code, Error::RequestRejected)
        raise klass.new("Last.fm error #{code}: #{body['message']}", code: code, http_status: status)
      end
      raise Error::RateLimited.new("Last.fm returned HTTP 429", http_status: status) if status == 429
      raise Error::Temporary.new("Last.fm returned HTTP #{status}", http_status: status) if status >= 500
      raise Error::RequestRejected.new("Last.fm returned HTTP #{status}", http_status: status) unless status == 200
      raise Error::BadResponse.new("Last.fm returned a response that is not JSON", http_status: status) unless body.is_a?(Hash)

      body
    end
  end
end
