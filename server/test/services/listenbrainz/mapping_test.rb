require "test_helper"

# A ListenBrainz listen as a Listening::Event (docs/listenbrainz-spotify-feasibility.md §4.1).
class Listenbrainz::MappingTest < ActiveSupport::TestCase
  LISTENS = JSON.parse(Rails.root.join("test/fixtures/files/listenbrainz/listens.json").read).then { |f| f.is_a?(Hash) ? f.dig("payload", "listens") : f }

  test "a Web Scrobbler listen: seconds become milliseconds, the start time is a start time, the opinions are context" do
    e = Listenbrainz::Mapping.event(LISTENS[0])
    assert_equal [ "listenbrainz", "listen_started_at", Time.at(1_760_000_000).utc, "1760000000", 230_000 ],
                 [ e.provider, e.timestamp_kind, e.reported_at, e.reported_at_raw, e.duration_ms ]
    assert_equal [ "Fixture Artist 1", "Fixture Track 1", "Fixture Release 1" ], [ e.artist_name, e.track_name, e.album_name ]
    assert_equal [ nil, nil, [], nil ], [ e.provider_track_id, e.provider_album_id, e.provider_artist_ids, e.isrc ]
    assert_equal "Web Scrobbler", e.context["submission_client"]
    assert_equal 1_760_000_114, e.context["inserted_at"]
    assert_equal "https://music.youtube.com/watch?v=video01&list=PLfixture01", e.context["origin_url"]
    assert_equal %w[recording_mbid release_mbid artist_mbids].sort, e.context["mbid_mapping"].keys.sort
  end

  test "a Pano listen without a release or a mapping maps too, and the event id never comes from the msid" do
    e = Listenbrainz::Mapping.event(LISTENS[8])
    assert_equal [ 179_000, "" ], [ e.duration_ms, e.album_name ]
    assert_nil e.context["mbid_mapping"] if LISTENS[8]["track_metadata"]["mbid_mapping"].nil?
    repeat_a, repeat_b = LISTENS[4], LISTENS[5]
    assert_equal repeat_a["recording_msid"], repeat_b["recording_msid"]
    assert_not_equal Listenbrainz::Mapping.event(repeat_a).source_event_id, Listenbrainz::Mapping.event(repeat_b).source_event_id
    assert_equal Listenbrainz::Mapping.event(repeat_a).source_event_id, Listenbrainz::Mapping.event(repeat_a.merge("recording_msid" => "changed")).source_event_id,
                 "the same play re-mapped by ListenBrainz keeps its id"
  end

  test "a listen from ListenBrainz's own Spotify import carries Spotify's end-of-play time and ids" do
    listen = {
      "listened_at" => 1_760_000_500, "inserted_at" => 1_760_000_510, "recording_msid" => "m",
      "track_metadata" => { "artist_name" => "Band", "track_name" => "Song", "release_name" => "Album",
                            "additional_info" => { "duration_ms" => 200_000, "isrc" => "GBAAA0000001", "music_service" => "spotify.com",
                                                   "submission_client" => "listenbrainz", "spotify_id" => "https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC",
                                                   "spotify_album_id" => "https://open.spotify.com/album/2noRn2Aes5aoNVsU6iWThc",
                                                   "spotify_artist_ids" => [ "https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF" ] } }
    }
    e = Listenbrainz::Mapping.event(listen)
    assert_equal "spotify_played_at", e.timestamp_kind
    assert_equal [ "4uLU6hMCjMI75M1A2tKUQC", "2noRn2Aes5aoNVsU6iWThc", [ "0OdUWJ0sBjDrqHygGUXeCF" ], "GBAAA0000001", 200_000 ],
                 [ e.provider_track_id, e.provider_album_id, e.provider_artist_ids, e.isrc, e.duration_ms ]
  end

  test "a listen without names or a time is malformed" do
    assert_raises(Listenbrainz::Mapping::Malformed) { Listenbrainz::Mapping.event({ "listened_at" => 1, "track_metadata" => { "artist_name" => "A" } }) }
    assert_raises(Listenbrainz::Mapping::Malformed) { Listenbrainz::Mapping.event({ "track_metadata" => { "artist_name" => "A", "track_name" => "T" } }) }
  end
end
