require "net/http"
require "json"

module MusicBrainz
  # Read-only MusicBrainz web service client (https://musicbrainz.org/doc/MusicBrainz_API).
  #
  # - At most one request per second across every Runout process: the shared request pacer
  #   (api_request_slots), under its own key.
  # - An identifying User-Agent, with the owner's contact when MUSICBRAINZ_CONTACT is set.
  # - 503 or 429 (rate limited) pauses every process before it raises; network failures raise too.
  #   Callers decide about retries (Metadata::Enricher).
  # - A merged MBID is answered with the surviving entity: `canonical_id` records it.
  class Client
    BASE = "https://musicbrainz.org/ws/2".freeze
    VERSION = "0.1".freeze
    INTERVAL = 1.1 # seconds: under MusicBrainz's one request per second

    Response = Data.define(:status, :url, :body, :duration_ms)

    class RateLimited < StandardError
      attr_reader :retry_after

      def initialize(message, retry_after:)
        super(message)
        @retry_after = retry_after
      end
    end

    class Unavailable < StandardError; end

    def self.user_agent
      contact = ENV["MUSICBRAINZ_CONTACT"].presence
      "Runout/#{VERSION} (personal listening archive#{"; #{contact}" if contact})"
    end

    def initialize(pacer: Lastfm::RequestPacer.new(key: "musicbrainz", interval: INTERVAL), http: nil)
      @pacer = pacer
      @http = http || method(:perform)
    end

    attr_reader :requests

    # GET artist/{mbid} with genres and tags. Status 200 (body parsed), 404 or 400; raises
    # RateLimited or Unavailable for answers worth retrying.
    def artist(mbid)
      get("#{BASE}/artist/#{mbid}?inc=genres+tags&fmt=json")
    end

    # GET release/{mbid} with its release group: the link from a release to its release group.
    def release(mbid)
      get("#{BASE}/release/#{mbid}?inc=artist-credits+release-groups&fmt=json")
    end

    private

    def get(url)
      @pacer.reserve!
      @requests = @requests.to_i + 1
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, body, retry_after = @http.call(url)
      duration = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      if [ 429, 503 ].include?(status)
        wait = retry_after || 5.0
        @pacer.cool_down!(wait)
        raise RateLimited.new("MusicBrainz asked Runout to slow down (HTTP #{status})", retry_after: wait)
      end
      raise Unavailable, "MusicBrainz answered HTTP #{status}" if status >= 500

      Response.new(status: status, url: url, body: status == 200 ? JSON.parse(body) : nil, duration_ms: duration)
    rescue JSON::ParserError => e
      raise Unavailable, "MusicBrainz sent an unreadable answer: #{e.message}"
    end

    def perform(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        res = http.request(Net::HTTP::Get.new(uri, "User-Agent" => self.class.user_agent, "Accept" => "application/json"))
        [ res.code.to_i, res.body.to_s, res["Retry-After"]&.to_f ]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      raise Unavailable, "MusicBrainz could not be reached: #{e.class}"
    end
  end
end
