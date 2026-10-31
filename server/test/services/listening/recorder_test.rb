require "test_helper"

# Listening sources, stage 1 (docs/spotify-plan.md §2–5): provider observations, idempotence,
# repeats and same-second plays, cross-source matching with Last.fm plays, review, the per-source
# storage gate, and the integrity of Last.fm history. Synthetic data only; no network.
class Listening::RecorderTest < ActiveSupport::TestCase
  include HistoryHelpers

  T = Time.utc(2026, 10, 31, 12, 0, 0)

  setup do
    @spotify_flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    @user = history_user
    @source = spotify_source(@user)
    @recorder = Listening::Recorder.new(@source, now: -> { T + 1.hour })
  end

  teardown { Rails.configuration.x.spotify_ingestion_enabled = @spotify_flag }

  def spotify_source(user, account: "spotify-#{user.id}")
    ListeningSource.create!(user: user, provider: "spotify", external_account_id: account, display_name: "Listener", connected_at: T)
  end

  # A Spotify report: `at` is played_at (end of playback), to the millisecond.
  def event(at, track: "Song", artist: "Band", album: "Album", duration: 200_000, track_id: "spotify:#{track}", isrc: nil)
    ms = (at.to_f * 1000).round
    Listening::Event.new(provider: "spotify", source_event_id: ms.to_s, reported_at: Time.at(Rational(ms, 1000)).utc,
                         reported_at_raw: Time.at(Rational(ms, 1000)).utc.iso8601(3), timestamp_kind: "spotify_played_at",
                         duration_ms: duration, artist_name: artist, track_name: track, album_name: album, provider_track_id: track_id,
                         provider_album_id: "album:#{album}", provider_artist_ids: [ "artist:#{artist}" ], isrc: isrc, context: nil)
  end

  # A Last.fm play stored by the importer: start time to the second.
  def lastfm_play(at, track: "Song", artist: "Band", album: "Album", user: @user, seq: 0)
    scrobble(user, at: at, seq: seq, variant: variant(artist: artist, track: track, album: album))
  end

  def lastfm_fingerprint
    Scrobble.from_lastfm.order(:id).pluck(:id, :played_at, :seq, :name_variant_id, :removed_at, :source)
  end

  test "a new Spotify play is stored once, at its own timestamp, with what Spotify sent kept apart" do
    played = T + 0.123
    result = @recorder.record!(event(played, isrc: "GBAYE0000001"))
    assert_equal :created, result.outcome

    s = Scrobble.sole
    assert_equal [ "spotify", T, 0 ], [ s.source, s.played_at, s.seq ]
    o = ListeningObservation.sole
    assert_equal [ s.id, "created", nil ], [ o.scrobble_id, o.link_state, o.linked_by ]
    assert_equal 123_000, o.reported_at.usec, "milliseconds kept on the observation"
    assert_equal [ "2026-10-31T12:00:00.123Z", "spotify_played_at", 200_000 ], [ o.reported_at_raw, o.timestamp_kind, o.duration_ms ]
    assert_equal [ "spotify:Song", "album:Album", [ "artist:Band" ], "GBAYE0000001" ],
                 [ o.provider_track_id, o.provider_album_id, o.provider_artist_ids, o.isrc ]
    v = o.name_variant
    assert_equal [ "Band", "Song", "Album" ], [ v.artist_name, v.track_name, v.album_name ]
    assert_equal [ nil, nil, nil ], [ v.artist_mbid, v.track_mbid, v.album_mbid ], "no Spotify ID or ISRC is ever an MBID"
    assert v.artist_id, "linked to the catalogue without MusicBrainz"
    assert_equal [ T + 1.hour, T + 1.hour ], [ o.received_at, o.last_seen_at ]
  end

  test "fetching the same report again never adds a play" do
    e = event(T + 0.5)
    3.times { @recorder.record!(e) }
    assert_equal 1, Scrobble.count
    o = ListeningObservation.sole
    assert_equal [ 3, nil ], [ o.times_seen, o.later_values ]
    assert_equal({ seen: 2 }, @recorder.record_all!([ e, e ]))
  end

  test "a later report of the same play with changed track or album data is noted, never applied" do
    @recorder.record!(event(T + 0.5, album: "Album"))
    result = @recorder.record!(event(T + 0.5, album: "Album (Deluxe)", track_id: "spotify:relinked"))
    assert_equal :changed, result.outcome
    o = ListeningObservation.sole
    assert_equal({ "provider_track_id" => "spotify:relinked", "provider_album_id" => "album:Album (Deluxe)", "album_name" => "Album (Deluxe)" },
                 o.later_values)
    assert_equal [ "Album", "spotify:Song" ], [ o.name_variant.album_name, o.provider_track_id ]
    assert_equal 1, Scrobble.count
  end

  test "repeat listens and same-second plays stay separate, in play order" do
    outcomes = @recorder.record_all!([ event(T + 400.2), event(T + 200.9), event(T + 200.1), event(T + 600.0, track: "Other") ])
    assert_equal({ created: 4 }, outcomes)
    assert_equal [ [ T + 200, 0 ], [ T + 200, 1 ], [ T + 400, 0 ], [ T + 600, 0 ] ], Scrobble.order(:played_at, :seq).pluck(:played_at, :seq)
    assert_equal [ "200100", "200900" ], ListeningObservation.joins(:scrobble).where(scrobbles: { played_at: T + 200 }).order("scrobbles.seq")
                                                             .pluck(:source_event_id).map { |id| (id.to_i - (T.to_i * 1000)).to_s }
  end

  test "a play Last.fm already has is linked to it: counted once, both reports kept, the Last.fm play untouched" do
    lastfm = lastfm_play(T) # started at T, a 200 s track
    before = lastfm_fingerprint
    result = @recorder.record!(event(T + 200.4))

    assert_equal :linked, result.outcome
    assert_equal 1, Scrobble.count
    o = ListeningObservation.sole
    assert_equal [ lastfm.id, "linked", "rule" ], [ o.scrobble_id, o.link_state, o.linked_by ]
    assert_equal [ "one_same_play", "same", 200.4 ], [ o.match_evidence["reason"], o.match_evidence.dig("candidates", 0, "identity"),
                                                       o.match_evidence.dig("candidates", 0, "seconds_before_report") ]
    assert_equal before, lastfm_fingerprint
  end

  test "names are compared normalised; a play skipped after the scrobble threshold still matches" do
    lastfm_play(T, artist: "BAND", track: "song")
    assert_equal :linked, @recorder.record!(event(T + 130)).outcome, "stopped at 130 s of 200: Last.fm counted it"
  end

  test "a track played twice in a row: each Spotify report links to its own Last.fm play" do
    first = lastfm_play(T)
    second = lastfm_play(T + 200)
    assert_equal({ linked: 2 }, @recorder.record_all!([ event(T + 400), event(T + 200) ]))
    assert_equal [ first.id, second.id ], ListeningObservation.order(:reported_at).pluck(:scrobble_id)
  end

  test "different plays at the same time are not merged; a play is attested once per provider" do
    lastfm_play(T, track: "Something Else")
    assert_equal :created, @recorder.record!(event(T + 200)).outcome, "same time, different track: separate plays"

    linked_to = lastfm_play(T + 1000)
    assert_equal :linked, @recorder.record!(event(T + 1200)).outcome
    assert_equal :created, @recorder.record!(event(T + 1200.5)).outcome, "the Last.fm play is already attested by Spotify"
    assert_equal 1, ListeningObservation.where(scrobble_id: linked_to.id).count
    assert_equal 4, Scrobble.count
  end

  test "uncertain matches go to review: several equal candidates, or only a similar title" do
    lastfm_play(T)
    lastfm_play(T + 20)
    r = @recorder.record!(event(T + 200))
    assert_equal :pending_review, r.outcome
    assert_equal [ nil, "several_same_plays", 2 ], [ r.observation.scrobble_id, r.observation.match_evidence["reason"],
                                                     r.observation.match_evidence["candidates"].size ]

    lastfm_play(T + 5000, track: "Song - 2011 Remaster")
    r = @recorder.record!(event(T + 5200))
    assert_equal [ :pending_review, "similar_play" ], [ r.outcome, r.observation.match_evidence["reason"] ]
    assert_equal 3, Scrobble.count, "nothing added or merged while undecided"
  end

  test "a person decides: the same play as a candidate, or a separate one; audited" do
    a = lastfm_play(T)
    lastfm_play(T + 20)
    pending = @recorder.record!(event(T + 200)).observation
    assert_raises(Listening::Review::Invalid) { Listening::Review.link!(pending, 999_999, by: @user) }
    assert_equal :linked, Listening::Review.link!(pending, a.id, by: @user)
    assert_equal [ a.id, "linked", "person" ], pending.reload.values_at(:scrobble_id, :link_state, :linked_by)
    assert_raises(Listening::Review::Invalid) { Listening::Review.separate!(pending, by: @user) }

    lastfm_play(T + 5000, track: "Song (Live)")
    other = @recorder.record!(event(T + 5200)).observation
    assert_equal :kept_separate, Listening::Review.separate!(other, by: @user)
    assert_equal [ "spotify", T + 5200, 0 ], other.reload.scrobble.values_at(:source, :played_at, :seq)
    assert_equal %w[linked kept_separate], ReviewDecision.where(subject_type: "ListeningObservation").order(:id).pluck(:action)
  end

  test "another user's plays are never candidates, and each account belongs to one user" do
    other = history_user("other")
    lastfm_play(T, user: other)
    assert_equal :created, @recorder.record!(event(T + 200)).outcome
    assert_equal 1, Scrobble.where(user: @user).count
    assert_raises(ActiveRecord::RecordNotUnique) { spotify_source(other, account: @source.external_account_id) }
  end

  test "an interrupted batch keeps what was stored and resumes without duplicates" do
    events = [ event(T + 200), event(T + 400), event(T + 600) ]
    # Fails after storing the second event's play, before its observation: a crash mid-event.
    crashing = Class.new(Listening::Recorder) do
      define_method(:create_scrobble!) do |*args|
        super(*args).tap { raise Interrupt, "crash" if (@calls = @calls.to_i + 1) == 2 }
      end
    end
    assert_raises(Interrupt) { crashing.new(@source).record_all!(events) }
    assert_equal 1, Scrobble.count, "the second event rolled back whole: no play without its observation"
    assert_equal({ seen: 1, created: 2 }, @recorder.record_all!(events))
    assert_equal 3, Scrobble.count
  end

  test "Spotify plays are written only with Spotify ingestion on, and switching it on never lets Last.fm history in" do
    Rails.configuration.x.history_import_enabled = "false" # HistoryHelpers switches it back
    assert_equal :created, @recorder.record!(event(T + 200)).outcome, "Last.fm storage off: Spotify still works"
    assert_raises(HistoryImport::DisabledError) { lastfm_play(T + 9000) }

    Rails.configuration.x.spotify_ingestion_enabled = "false"
    assert_raises(ListeningStorage::DisabledError) { @recorder.record!(event(T + 400)) }
    assert_equal 1, Scrobble.count
  end
end
