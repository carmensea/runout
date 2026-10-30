module Lastfm
  # One parsed page of user.getRecentTracks. Plain values only: nothing here is persisted.
  #
  # Shape verified against the live API (docs/lastfm-api-findings.md):
  # - `@attr` carries page, perPage, totalPages and total, all as strings.
  # - `track` is an array; a single object is also accepted, a known Last.fm quirk.
  # - The "now playing" entry has `@attr.nowplaying = "true"` and no `date`; it is excluded.
  # - Strings are kept exactly as received (no trimming or case changes); empty MBIDs become nil.
  # - Nothing is dropped silently. Entries without a usable date are counted in `undated_count`;
  #   entries that aren't track objects, or have no track or artist name, in `malformed_count`.
  # - Same-second and identical plays are separate entries, in the order Last.fm returned them.
  RecentTracksPage = Data.define(:page, :per_page, :total_pages, :total, :scrobbles, :now_playing,
                                 :undated_count, :malformed_count) do
    def self.parse(body)
      container = body["recenttracks"]
      raise Error::BadResponse, "user.getRecentTracks response has no recenttracks" unless container.is_a?(Hash)

      attrs = container["@attr"] || {}
      entries = container["track"]
      entries = [ entries ] if entries.is_a?(Hash)
      entries = [] unless entries.is_a?(Array)

      now_playing = false
      undated = 0
      malformed = 0
      scrobbles = entries.filter_map do |entry|
        unless entry.is_a?(Hash) && entry.key?("name") && entry.key?("artist")
          malformed += 1
          next
        end
        if entry.dig("@attr", "nowplaying") == "true"
          now_playing = true
          next
        end
        uts = entry.dig("date", "uts").to_s
        unless uts.match?(/\A\d+\z/)
          undated += 1
          next
        end
        Scrobble.from_entry(entry, Time.at(uts.to_i).utc)
      end

      new(
        page: integer(attrs["page"]),
        per_page: integer(attrs["perPage"]),
        total_pages: integer(attrs["totalPages"]),
        total: integer(attrs["total"]),
        scrobbles: scrobbles,
        now_playing: now_playing,
        undated_count: undated,
        malformed_count: malformed
      )
    end

    def self.integer(value)
      Integer(value.to_s, 10, exception: false)
    end
  end

  # A dated play as Last.fm reported it.
  Scrobble = Data.define(:played_at, :artist, :artist_mbid, :track, :track_mbid, :album, :album_mbid) do
    def self.from_entry(entry, played_at)
      new(
        played_at: played_at,
        artist: text(entry["artist"]),
        artist_mbid: mbid(entry["artist"]),
        track: entry["name"].to_s,
        track_mbid: entry["mbid"].presence,
        album: text(entry["album"]),
        album_mbid: mbid(entry["album"])
      )
    end

    # Non-extended responses use {"#text", "mbid"}; extended ones use {"name", "mbid"}.
    def self.text(node)
      return node.to_s unless node.is_a?(Hash)

      (node["#text"] || node["name"]).to_s
    end

    def self.mbid(node)
      node.is_a?(Hash) ? node["mbid"].presence : nil
    end
  end
end
