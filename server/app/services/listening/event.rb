module Listening
  # A provider's report of one completed play, before it is stored (docs/spotify-plan.md §3).
  #
  # - `source_event_id`: unique per source account. Spotify sends no event ID, so it is the exact
  #   `played_at` in milliseconds: one account can't finish two plays in the same millisecond, while
  #   repeats of a track, same-second plays included, stay distinct. The track ID is deliberately not
  #   part of it: a later report of the same play with different track data is the same event.
  # - `reported_at` / `reported_at_raw`: the provider's timestamp, parsed at full precision and as
  #   sent. `timestamp_kind` names what it means (KINDS).
  # - Provider IDs stay in their own fields: never MusicBrainz IDs, and an ISRC is never a
  #   recording ID.
  Event = Data.define(:provider, :source_event_id, :reported_at, :reported_at_raw, :timestamp_kind, :duration_ms,
                      :artist_name, :track_name, :album_name, :provider_track_id, :provider_album_id, :provider_artist_ids,
                      :isrc, :context)

  # What each provider's timestamp means, and where another provider's start time for the same play
  # can lie relative to it (Listening::CrossSource).
  KINDS = {
    # Last.fm: when the track started, to the second (scrobbles.played_at).
    "lastfm_start" => { meaning: "start of the play, second precision" },
    # Spotify Recently Played `played_at`: documented only as "the date and time the track was
    # played", with millisecond precision. Widely reported to mark the end of playback; to be
    # measured against real plays before ingestion is switched on (docs/spotify-plan.md §4). The
    # candidate window covers both readings.
    "spotify_played_at" => { meaning: "Spotify played_at (documented as when the track was played; believed to be the end of playback)" },
    # ListenBrainz listens from scrobblers (Pano, Web Scrobbler): when the track started, to the
    # second. Linked to other providers' plays by start time (Listening::CrossSource).
    "listen_started_at" => { meaning: "start of the play, second precision, as the scrobbler submitted it" },
    # A ListenBrainz listen from a client whose timestamp convention is not known: kept as submitted.
    "listenbrainz_listened_at" => { meaning: "ListenBrainz listened_at as submitted; start or end of play unknown, see context submission_client" }
  }.freeze
end
