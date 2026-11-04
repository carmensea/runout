module Lastfm
  # One parsed page of user.getLovedTracks (https://www.last.fm/api/show/user.getLovedTracks). Plain
  # values only: nothing here is persisted. Shape checked against the live API on 2026-11-04:
  # `@attr` carries page, perPage, totalPages and total as strings; each track has `name`, `mbid`,
  # `url`, `artist` {name, mbid, url} and `date` {uts, #text}: the moment the song was loved.
  # Strings are kept exactly as received; empty MBIDs become nil. Entries without a track or artist
  # name, or without a date, are counted in `malformed_count`, never dropped silently.
  LovedTracksPage = Data.define(:page, :per_page, :total_pages, :total, :tracks, :malformed_count) do
    Loved = Data.define(:artist_name, :artist_mbid, :track_name, :track_mbid, :loved_at, :url)

    def self.parse(body)
      container = body["lovedtracks"]
      raise Error::BadResponse, "user.getLovedTracks response has no lovedtracks" unless container.is_a?(Hash)

      attrs = container["@attr"] || {}
      entries = container["track"]
      entries = [ entries ] if entries.is_a?(Hash)
      entries = [] unless entries.is_a?(Array)

      malformed = 0
      tracks = entries.filter_map do |entry|
        uts = entry.is_a?(Hash) ? entry.dig("date", "uts").to_s : ""
        artist = entry.is_a?(Hash) && entry["artist"].is_a?(Hash) ? entry["artist"] : nil
        unless artist && entry["name"].is_a?(String) && entry["name"] != "" && artist["name"].is_a?(String) && artist["name"] != "" && uts.match?(/\A\d+\z/)
          malformed += 1
          next
        end
        Loved.new(artist_name: artist["name"], artist_mbid: artist["mbid"].presence, track_name: entry["name"],
                  track_mbid: entry["mbid"].presence, loved_at: Time.at(uts.to_i).utc, url: entry["url"].presence)
      end

      new(page: RecentTracksPage.integer(attrs["page"]), per_page: RecentTracksPage.integer(attrs["perPage"]),
          total_pages: RecentTracksPage.integer(attrs["totalPages"]), total: RecentTracksPage.integer(attrs["total"]),
          tracks: tracks, malformed_count: malformed)
    end
  end
end
