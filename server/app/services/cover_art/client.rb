require "net/http"
require "json"

module CoverArt
  # Read-only Cover Art Archive client (https://musicbrainz.org/doc/Cover_Art_Archive/API). Follows the
  # archive's redirects (to archive.org), paced by its own key in the shared request pacer, and keeps
  # only HTTPS image URLs on approved hosts.
  class Client
    BASE = "https://coverartarchive.org".freeze
    INTERVAL = 1.0
    APPROVED_HOSTS = [ "coverartarchive.org", "archive.org" ].freeze
    MAX_REDIRECTS = 4

    Cover = Data.define(:image_id, :thumbnail_250, :thumbnail_500, :thumbnail_1200, :source_url)

    def initialize(pacer: Lastfm::RequestPacer.new(key: "coverartarchive", interval: INTERVAL), http: nil)
      @pacer = pacer
      @http = http || method(:perform)
    end

    attr_reader :requests

    # The front cover of a release or release group, nil when it has none. Raises
    # MusicBrainz::Client::RateLimited or Unavailable for answers worth retrying.
    def front(kind, mbid)
      raise ArgumentError, "kind must be release or release-group" unless %w[release release-group].include?(kind)

      url = "#{BASE}/#{kind}/#{mbid}"
      status, body = get(url)
      return nil if status == 404
      raise MusicBrainz::Client::Unavailable, "Cover Art Archive answered HTTP #{status}" unless status == 200

      images = Array(JSON.parse(body)["images"])
      image = images.find { |i| i["front"] && i["approved"] } || images.find { |i| i["front"] }
      return nil unless image

      thumbs = image["thumbnails"] || {}
      Cover.new(image_id: image["id"].to_s,
                thumbnail_250: approved(thumbs["250"] || thumbs["small"]),
                thumbnail_500: approved(thumbs["500"] || thumbs["large"]),
                thumbnail_1200: approved(thumbs["1200"]),
                source_url: url)
    rescue JSON::ParserError => e
      raise MusicBrainz::Client::Unavailable, "Cover Art Archive sent an unreadable answer: #{e.message}"
    end

    # An HTTPS URL on an approved host (subdomains included), or nil. http is upgraded.
    def self.approved(url)
      uri = URI.parse(url.to_s.sub(/\Ahttp:/, "https:"))
      return nil unless uri.is_a?(URI::HTTPS) && uri.host
      return nil unless APPROVED_HOSTS.any? { |h| uri.host == h || uri.host.end_with?(".#{h}") }

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    private

    def approved(url) = self.class.approved(url)

    def get(url, hops = MAX_REDIRECTS)
      @pacer.reserve!
      @requests = @requests.to_i + 1
      status, body, location, retry_after = @http.call(url)
      if [ 301, 302, 303, 307, 308 ].include?(status) && hops.positive?
        target = self.class.approved(URI.join(url, location.to_s).to_s)
        raise MusicBrainz::Client::Unavailable, "Cover Art Archive redirected to an unapproved host" unless target

        return get(target, hops - 1)
      end
      if [ 429, 503 ].include?(status)
        @pacer.cool_down!(retry_after || 5.0)
        raise MusicBrainz::Client::RateLimited.new("Cover Art Archive asked Runout to slow down (HTTP #{status})", retry_after: retry_after || 5.0)
      end
      [ status, body ]
    end

    def perform(url)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) do |http|
        res = http.request(Net::HTTP::Get.new(uri, "User-Agent" => MusicBrainz::Client.user_agent, "Accept" => "application/json"))
        [ res.code.to_i, res.body.to_s, res["Location"], res["Retry-After"]&.to_f ]
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      raise MusicBrainz::Client::Unavailable, "Cover Art Archive could not be reached: #{e.class}"
    end
  end
end
