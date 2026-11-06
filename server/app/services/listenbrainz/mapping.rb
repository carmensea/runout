require "digest"

module Listenbrainz
  # A ListenBrainz listen as a Listening::Event (docs/listenbrainz-spotify-feasibility.md §4.1).
  # Kept exactly: the submitted names, `listened_at`, the scrobbler's own fields and ListenBrainz's
  # opinions (`recording_msid`, `mbid_mapping`, `inserted_at`) in the context, never as identities.
  module Mapping
    class Malformed < StandardError; end

    SPOTIFY_URL = %r{\Ahttps?://open\.spotify\.com/(?:track|album|artist)/([A-Za-z0-9]+)}

    module_function

    def event(listen)
      meta = listen["track_metadata"]
      raise Malformed, "no track_metadata" unless meta.is_a?(Hash)

      listened_at = Integer(listen["listened_at"]) rescue raise(Malformed, "no listened_at")
      artist = meta["artist_name"].to_s
      track = meta["track_name"].to_s
      raise Malformed, "no track or artist name" if artist.strip.empty? || track.strip.empty?

      info = meta["additional_info"].is_a?(Hash) ? meta["additional_info"] : {}
      release = meta["release_name"].to_s
      from_spotify = info["music_service"].to_s == "spotify.com" && info["submission_client"].to_s == "listenbrainz"
      Listening::Event.new(
        provider: "listenbrainz",
        # Second plus the submitted names: two plays of one recording cannot share a second, and
        # the same play reported again (or re-mapped by ListenBrainz) keeps its id. Never the msid.
        source_event_id: "#{listened_at}:#{Digest::SHA1.hexdigest("#{artist}\n#{track}\n#{release}")[0, 16]}",
        reported_at: Time.at(listened_at).utc, reported_at_raw: listened_at.to_s,
        # ListenBrainz's own Spotify import stores Spotify's played_at verbatim; scrobblers submit the start.
        timestamp_kind: from_spotify ? "spotify_played_at" : "listen_started_at",
        duration_ms: duration_ms(info),
        artist_name: artist, track_name: track, album_name: release,
        provider_track_id: spotify_id(info["spotify_id"]), provider_album_id: spotify_id(info["spotify_album_id"]),
        provider_artist_ids: Array(info["spotify_artist_ids"]).filter_map { |u| spotify_id(u) },
        isrc: info["isrc"].presence,
        context: context(listen, info, meta["mbid_mapping"])
      )
    end

    # Scrobblers send `duration` in seconds, ListenBrainz's Spotify import `duration_ms`.
    def duration_ms(info)
      return Integer(info["duration_ms"]) if info["duration_ms"].is_a?(Numeric) || info["duration_ms"].to_s.match?(/\A\d+\z/)
      return (Float(info["duration"]) * 1000).round if info["duration"].is_a?(Numeric) || info["duration"].to_s.match?(/\A\d+(\.\d+)?\z/)

      nil
    end

    def spotify_id(value)
      value.to_s[SPOTIFY_URL, 1]
    end

    def context(listen, info, mapping)
      {
        "music_service" => info["music_service"], "music_service_name" => info["music_service_name"],
        "media_player" => info["media_player"], "submission_client" => info["submission_client"],
        "submission_client_version" => info["submission_client_version"], "origin_url" => info["origin_url"],
        "recording_msid" => listen["recording_msid"], "inserted_at" => listen["inserted_at"],
        "mbid_mapping" => mapping.is_a?(Hash) ? mapping.slice("recording_mbid", "release_mbid", "artist_mbids") : nil
      }.compact
    end
  end
end
