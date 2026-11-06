require "test_helper"

# Cross-provider dedup between ListenBrainz listens and Spotify plays (docs/listenbrainz-spotify-
# feasibility.md §4.3, PR C): start-time windows for start-stamped and end-stamped reports in both
# directions, the exact rule for one Spotify play seen through both Runout's Spotify and
# ListenBrainz's, genuine repeats kept, unknown stamps held for a person, strict user isolation.
# Synthetic data only; no network.
class Listening::CrossProviderTest < ActiveSupport::TestCase
  include HistoryHelpers

  T = Time.utc(2026, 11, 6, 12, 0, 0)
  SPOTIFY_ID = "4uLU6hMCjMI75M1A2tKUQC".freeze

  setup do
    @flags = %i[spotify_ingestion_enabled listenbrainz_ingestion_enabled].to_h { |f| [ f, Rails.configuration.x.public_send(f) ] }
    @flags.each_key { |f| Rails.configuration.x.public_send("#{f}=", "true") }
    @user = history_user("dana")
    @spotify = ListeningSource.create!(user: @user, provider: "spotify", external_account_id: "sp-dana", display_name: "Dana", connected_at: T)
    @lb = ListeningSource.create!(user: @user, provider: "listenbrainz", external_account_id: "dana_lb", display_name: "dana_lb", connected_at: T)
    @via_spotify = Listening::Recorder.new(@spotify, now: -> { T + 1.hour })
    @via_lb = Listening::Recorder.new(@lb, now: -> { T + 1.hour })
  end

  teardown { @flags.each { |f, v| Rails.configuration.x.public_send("#{f}=", v) } }

  # Runout's own Spotify report: `at` is played_at (end of playback), to the millisecond.
  def spotify_event(at, track: "Song", artist: "Band", duration: 200_000, track_id: SPOTIFY_ID)
    ms = (at.to_f * 1000).round
    Listening::Event.new(provider: "spotify", source_event_id: ms.to_s, reported_at: Time.at(Rational(ms, 1000)).utc,
                         reported_at_raw: Time.at(Rational(ms, 1000)).utc.iso8601(3), timestamp_kind: "spotify_played_at",
                         duration_ms: duration, artist_name: artist, track_name: track, album_name: "Album", provider_track_id: track_id,
                         provider_album_id: nil, provider_artist_ids: [], isrc: nil, context: nil)
  end

  # A ListenBrainz listen as Listenbrainz::Mapping produces it: `at` to the second, its meaning by kind.
  def lb_event(at, kind: "listen_started_at", track: "Song", artist: "Band", duration: 200_000, track_id: nil)
    s = at.to_i
    Listening::Event.new(provider: "listenbrainz", source_event_id: "#{s}:#{track}", reported_at: Time.at(s).utc, reported_at_raw: s.to_s,
                         timestamp_kind: kind, duration_ms: duration, artist_name: artist, track_name: track, album_name: "Album",
                         provider_track_id: track_id, provider_album_id: nil, provider_artist_ids: [], isrc: nil,
                         context: { "submission_client" => kind == "listen_started_at" ? "Pano Scrobbler" : "Unknown" })
  end

  def plays = Scrobble.where(user: @user).order(:played_at, :seq)

  test "a scrobbler's start time links to the Spotify play that ended a track later, in either order" do
    assert_equal :created, @via_spotify.record!(spotify_event(T + 200.4)).outcome
    result = @via_lb.record!(lb_event(T))
    assert_equal :linked, result.outcome
    assert_equal 1, plays.count, "one play, two observations"
    assert_equal [ "linked", "rule", "one_same_play", "spotify_played_at" ],
                 [ result.observation.link_state, result.observation.linked_by, result.observation.match_evidence["reason"],
                   result.observation.match_evidence.dig("candidates", 0, "kind") ]

    assert_equal :created, @via_lb.record!(lb_event(T + 1000)).outcome
    assert_equal :linked, @via_spotify.record!(spotify_event(T + 1200.4)).outcome, "Spotify arriving after ListenBrainz"
    assert_equal 2, plays.count
    assert_equal %w[spotify listenbrainz], plays.pluck(:source), "the first report of each play owns it"
  end

  test "a play skipped after the scrobble threshold still matches; one started too early or too late does not" do
    @via_spotify.record!(spotify_event(T + 130, duration: 200_000))
    assert_equal :linked, @via_lb.record!(lb_event(T)).outcome, "130 s of 200 heard: the scrobbler counted it"

    @via_spotify.record!(spotify_event(T + 2000, duration: 200_000))
    assert_equal :created, @via_lb.record!(lb_event(T + 1700)).outcome, "started 300 s before a 200 s track ended: the previous play"
    assert_equal :review, Listening::CrossSource.new(user_id: @user.id, provider: "listenbrainz").decide(lb_event(T + 1950), variant(track: "Song", artist: "Band")).action,
                 "started 50 s before the end: too short to count, a person decides"
  end

  test "the same Spotify play through Runout's Spotify and through ListenBrainz's import is one play, by the exact rule" do
    @via_spotify.record!(spotify_event(T + 200.4))
    result = @via_lb.record!(lb_event(T + 200, kind: "spotify_played_at", track_id: SPOTIFY_ID, track: "SONG (Remastered)"))
    assert_equal :linked, result.outcome, "names differ, the Spotify id and second agree"
    assert_equal [ "same_external_event", SPOTIFY_ID ], result.observation.match_evidence.values_at("rule", "provider_track_id")
    assert_equal 1, plays.count

    assert_equal :created, @via_lb.record!(lb_event(T + 900, kind: "spotify_played_at", track_id: SPOTIFY_ID)).outcome
    assert_equal :linked, @via_spotify.record!(spotify_event(T + 900.7)).outcome, "the other way round"
    assert_equal 2, plays.count
  end

  test "genuine repeats stay: two listens of one track link to two Spotify plays, and a third is a new play" do
    @via_spotify.record_all!([ spotify_event(T + 200), spotify_event(T + 400) ])
    assert_equal({ linked: 2 }, @via_lb.record_all!([ lb_event(T), lb_event(T + 200) ]))
    assert_equal :created, @via_lb.record!(lb_event(T + 400)).outcome
    assert_equal 3, plays.count
    assert_equal 1, ListeningObservation.where(provider: "listenbrainz", scrobble_id: plays.first.id).count, "attested once per provider"
  end

  test "a stamp whose meaning is unknown never links by itself: a same play nearby waits for a person" do
    @via_spotify.record!(spotify_event(T + 200.4))
    result = @via_lb.record!(lb_event(T + 200, kind: "listenbrainz_listened_at"))
    assert_equal [ :pending_review, "unknown_timestamp_kind" ], [ result.outcome, result.observation.match_evidence["reason"] ]
    assert_equal 1, plays.count, "not counted twice, not dropped"

    assert_equal :created, @via_lb.record!(lb_event(T + 5000, kind: "listenbrainz_listened_at")).outcome, "nothing nearby: a play"
    assert_equal :linked, Listening::Review.link!(result.observation, plays.first.id, by: @user)
  end

  test "another user's plays are never candidates, by either rule" do
    erin = history_user("erin")
    erin_spotify = ListeningSource.create!(user: erin, provider: "spotify", external_account_id: "sp-erin", display_name: "Erin", connected_at: T)
    Listening::Recorder.new(erin_spotify, now: -> { T }).record!(spotify_event(T + 200.4))

    assert_equal :created, @via_lb.record!(lb_event(T)).outcome
    assert_equal :created, @via_lb.record!(lb_event(T + 200, kind: "spotify_played_at", track_id: SPOTIFY_ID)).outcome
    assert_equal({ erin.id => 1, @user.id => 2 }, Scrobble.group(:user_id).count)
  end

  test "the existing Last.fm rule is unchanged: a Spotify report links to the Last.fm play that started a track earlier" do
    lastfm = scrobble(@user, at: T, variant: variant(track: "Song", artist: "Band"))
    result = @via_spotify.record!(spotify_event(T + 200.4))
    assert_equal [ :linked, lastfm.id, 200.4 ], [ result.outcome, result.observation.scrobble_id, result.observation.match_evidence.dig("candidates", 0, "seconds_before_report") ]
    assert_equal :linked, @via_lb.record!(lb_event(T)).outcome, "and the scrobbler's start time links to the same Last.fm play"
    assert_equal 1, plays.count
    assert_equal 2, ListeningObservation.where(scrobble_id: lastfm.id).count
  end
end
