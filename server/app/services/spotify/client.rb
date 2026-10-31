require "net/http"
require "json"
require "base64"

module Spotify
  # Read-only Spotify client: the accounts service (code exchange, refresh) and the two Web API
  # endpoints Runout uses, GET /me and GET /me/player/recently-played. Paced through the shared
  # request pacer under its own key. Tokens are passed in and never logged.
  class Client
    ACCOUNTS = "https://accounts.spotify.com/api/token".freeze
    API = "https://api.spotify.com/v1".freeze
    DEFAULT_INTERVAL = 0.5 # seconds between requests; SPOTIFY_MIN_REQUEST_INTERVAL overrides it
    MAX_RETRY_AFTER = 3600

    Tokens = Data.define(:access_token, :refresh_token, :expires_in, :scope)

    attr_reader :requests

    # `http`: ->(method, url, headers, form) { [status, body, headers] }, for tests.
    def initialize(pacer: nil, http: nil)
      @pacer = pacer || Lastfm::RequestPacer.new(key: "spotify", interval: ENV.fetch("SPOTIFY_MIN_REQUEST_INTERVAL", DEFAULT_INTERVAL).to_f)
      @http = http || method(:perform)
      @requests = 0
    end

    def exchange_code(code)
      tokens(grant_type: "authorization_code", code: code, redirect_uri: Config.redirect_uri)
    end

    # A refresh may return a new refresh token (rotation); nil means keep the current one.
    def refresh(refresh_token)
      tokens(grant_type: "refresh_token", refresh_token: refresh_token)
    end

    def me(access_token) = api(access_token, "/me")

    # Newest first. `before` / `after`: Unix milliseconds, mutually exclusive.
    def recently_played(access_token, limit: 50, before: nil, after: nil)
      raise ArgumentError, "before and after are mutually exclusive" if before && after

      query = { limit: limit, before: before, after: after }.compact
      api(access_token, "/me/player/recently-played?#{URI.encode_www_form(query)}")
    end

    private

    def tokens(form)
      basic = Base64.strict_encode64("#{Config.client_id}:#{Config.client_secret}")
      status, body, headers = call(:post, ACCOUNTS, { "Authorization" => "Basic #{basic}" }, form)
      data = parse(body)
      if status == 400 && data["error"] == "invalid_grant"
        raise Error::InvalidGrant.new("Spotify refused the authorisation (invalid_grant)", status: status)
      end

      check!(status, data, headers)
      Tokens.new(access_token: data.fetch("access_token"), refresh_token: data["refresh_token"].presence,
                 expires_in: data.fetch("expires_in").to_i, scope: data["scope"].to_s)
    end

    def api(access_token, path)
      status, body, headers = call(:get, "#{API}#{path}", { "Authorization" => "Bearer #{access_token}" }, nil)
      data = parse(body)
      check!(status, data, headers)
      data
    end

    def call(method, url, headers, form)
      @pacer.reserve!
      @requests += 1
      @http.call(method, url, headers.merge("Accept" => "application/json"), form)
    end

    def check!(status, data, headers)
      return if status.between?(200, 299)

      message = "Spotify answered HTTP #{status}#{": #{api_message(data)}" if api_message(data)}"
      case status
      when 401 then raise Error::Unauthorized.new(message, status: status)
      when 403 then raise Error::Forbidden.new(message, status: status)
      when 429
        wait = headers&.fetch("retry-after", nil).to_s.then { |v| v.match?(/\A\d+\z/) ? v.to_i : 30 }
        @pacer.cool_down!([ wait, MAX_RETRY_AFTER ].min)
        raise Error::RateLimited.new(message, retry_after: wait, reason: error_object(data)["reason"] || data["reason"])
      when 500..599 then raise Error::Unavailable.new(message, status: status)
      else raise Error::Rejected.new(message, status: status)
      end
    end

    # Spotify's error text, shortened. It never echoes credentials. The accounts service sends
    # `error` as a string with `error_description`; the Web API sends an `error` object.
    def api_message(data)
      text = data["error_description"] || error_object(data)["message"] || (data["error"] if data["error"].is_a?(String))
      text&.to_s&.truncate(200)
    end

    def error_object(data) = data["error"].is_a?(Hash) ? data["error"] : {}

    def parse(body)
      body.to_s.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def perform(method, url, headers, form)
      uri = URI(url)
      request = method == :post ? Net::HTTP::Post.new(uri, headers) : Net::HTTP::Get.new(uri, headers)
      request.set_form_data(form) if form
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        res = http.request(request)
        [ res.code.to_i, res.body.to_s, res.to_hash.transform_values(&:first) ]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError, EOFError => e
      raise Error::Unavailable, "Spotify could not be reached: #{e.class}"
    end
  end
end
