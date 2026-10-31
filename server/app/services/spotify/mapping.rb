module Spotify
  # A Recently Played item as a Listening::Event (docs/spotify-plan.md §2–4). Only what the play
  # needs is kept: the exact names, Spotify's IDs, the ISRC as an ISRC, and the play's context.
  # The artist is the first credited one, as Spotify's own Last.fm scrobbling reports it; all
  # artist IDs are kept.
  module Mapping
    class Malformed < StandardError; end

    module_function

    def event(item)
      raw = item["played_at"].to_s
      track = item["track"]
      raise Malformed, "no played_at" if raw.empty?
      raise Malformed, "not a track" unless track.is_a?(Hash) && (track["type"].nil? || track["type"] == "track")

      reported_at = Time.iso8601(raw).utc
      artists = Array(track["artists"])
      name = track["name"].to_s
      artist = artists.first&.fetch("name", nil).to_s
      raise Malformed, "no track or artist name" if name.strip.empty? || artist.strip.empty?

      album = track["album"] || {}
      Listening::Event.new(
        provider: "spotify", source_event_id: (reported_at.to_r * 1000).floor.to_s, reported_at: reported_at, reported_at_raw: raw,
        timestamp_kind: "spotify_played_at", duration_ms: track["duration_ms"]&.to_i, artist_name: artist, track_name: name,
        album_name: album["name"].to_s, provider_track_id: track["id"], provider_album_id: album["id"],
        provider_artist_ids: artists.filter_map { |a| a["id"] }, isrc: track.dig("external_ids", "isrc"),
        context: item["context"]&.slice("type", "uri")
      )
    rescue ArgumentError => e
      raise Malformed, "unreadable played_at: #{e.message}"
    end
  end
end
