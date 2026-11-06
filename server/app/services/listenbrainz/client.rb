require "net/http"

module Listenbrainz
  # The ListenBrainz API (docs/listenbrainz-spotify-feasibility.md §2): one request a second through
  # the shared pacer (api_request_slots, key "listenbrainz"), a User-Agent naming the app, and the
  # rate-limit headers honoured. The user's token goes in the Authorization header only, is never
  # logged, and in PR A is used for exactly one call: validate-token.
  class Client
    API = "https://api.listenbrainz.org/1".freeze
    DEFAULT_INTERVAL = 1.0 # seconds between requests, as the API documentation asks
    MAX_RETRY_AFTER = 3600

    def initialize(pacer: nil, http: nil)
      @pacer = pacer || Lastfm::RequestPacer.new(key: "listenbrainz", interval: ENV.fetch("LISTENBRAINZ_MIN_REQUEST_INTERVAL", DEFAULT_INTERVAL).to_f)
      @http = http || method(:perform)
    end

    # The ListenBrainz username the token belongs to, or nil when ListenBrainz says it is invalid.
    def validate_token(token)
      data = get("/validate-token", token: token)
      data["valid"] == true ? data["user_name"].to_s.presence : nil
    end

    def self.user_agent = "Runout/1.0 (#{Rails.configuration.x.app_origin})"

    private

    def get(path, token: nil)
      begin
        @pacer.reserve!
      rescue Lastfm::Error::RateLimited => e
        raise Error::RateLimited.new("ListenBrainz requests are paused after a rate limit (#{e.retry_after.to_f.ceil} s left)", retry_after: e.retry_after.to_f.ceil)
      end
      headers = { "Accept" => "application/json", "User-Agent" => self.class.user_agent }
      headers["Authorization"] = "Token #{token}" if token
      status, body, response_headers = @http.call(:get, "#{API}#{path}", headers)
      data = parse(body)
      check!(status, data, response_headers)
      data
    end

    def check!(status, data, headers)
      return if status.between?(200, 299)

      message = "ListenBrainz answered HTTP #{status}#{": #{data['error'].to_s.truncate(200)}" if data['error'].present?}"
      case status
      when 429
        wait = headers&.fetch("retry-after", nil).to_s.then { |v| v.match?(/\A\d+\z/) ? v.to_i : 60 }
        @pacer.cool_down!([ wait, MAX_RETRY_AFTER ].min)
        raise Error::RateLimited.new(message, retry_after: wait)
      when 500..599 then raise Error::Unavailable.new(message, status: status)
      else raise Error::Rejected.new(message, status: status)
      end
    end

    def parse(body)
      body.to_s.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end

    def perform(_method, url, headers)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        res = http.request(Net::HTTP::Get.new(uri, headers))
        [ res.code.to_i, res.body.to_s, res.to_hash.transform_values(&:first) ]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
           OpenSSL::SSL::SSLError, EOFError => e
      raise Error::Unavailable, "ListenBrainz could not be reached: #{e.class}"
    end
  end
end
