require "digest"

module Listenbrainz
  # A ListenBrainz listen as a Listening::Event (docs/listenbrainz-spotify-feasibility.md §4.1).
  # Kept exactly: the submitted names, `listened_at`, the scrobbler's own fields and ListenBrainz's
  # opinions (`recording_msid`, `mbid_mapping`, `inserted_at`) in the context, never as identities.
  module Mapping
    class Malformed < StandardError; end

    SPOTIFY_URL = %r{\Ahttps?://open\.spotify\.com/(?:track|album|artist)/([A-Za-z0-9]+)}
    # Scrobblers documented to submit the moment playback started (Last.fm semantics). Any other
    # client's `listened_at` is kept as submitted with its meaning unknown: PR C reconciles kinds.
    START_TIME_CLIENTS = [ "Web Scrobbler", "Pano Scrobbler" ].freeze

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
      Listening::Event.new(
        provider: "listenbrainz",
        # Second plus the submitted names: repeats at different seconds and different tracks in one
        # second are distinct; the same play reported again (or re-mapped by ListenBrainz) keeps its
        # id. Never the msid. Limitation: one track reported twice in the same second collapses to
        # one play here. ListenBrainz itself keeps one listen per user, second and recording_msid
        # (the id it derives from the submitted names: listenbrainz-server's unique index
        # listened_at_user_id_recording_msid_ndx_listen), so such a pair is already one listen
        # there and cannot be told apart by anyone reading the public API.
        source_event_id: "#{listened_at}:#{Digest::SHA1.hexdigest("#{artist}\n#{track}\n#{release}")[0, 16]}",
        reported_at: Time.at(listened_at).utc, reported_at_raw: listened_at.to_s,
        timestamp_kind: timestamp_kind(info),
        duration_ms: duration_ms(info),
        artist_name: artist, track_name: track, album_name: release,
        provider_track_id: spotify_id(info["spotify_id"]), provider_album_id: spotify_id(info["spotify_album_id"]),
        provider_artist_ids: Array(info["spotify_artist_ids"]).filter_map { |u| spotify_id(u) },
        isrc: info["isrc"].presence,
        context: context(listen, info, meta["mbid_mapping"])
      )
    end

    # What `listened_at` means depends on who submitted it: ListenBrainz's own Spotify import copies
    # Spotify's played_at (end of play); known scrobblers submit the start; anything else is kept as
    # submitted with the client named in the context, its meaning decided in PR C, not here.
    def timestamp_kind(info)
      client = info["submission_client"].to_s
      return "spotify_played_at" if info["music_service"].to_s == "spotify.com" && client == "listenbrainz"
      return "listen_started_at" if START_TIME_CLIENTS.any? { |c| client.downcase.start_with?(c.downcase) }

      "listenbrainz_listened_at"
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
