require "test_helper"

# Merging one database's Spotify record into another (docs/railway-deployment.md §6). Both "sides"
# live in the test database: the record is exported, removed, then merged back beside Last.fm plays.
class Listening::ArchiveMergeTest < ActiveSupport::TestCase
  include HistoryHelpers

  T = Time.utc(2026, 10, 31, 12, 0, 0)

  setup do
    @flags = [ Rails.configuration.x.spotify_ingestion_enabled, Rails.configuration.x.history_import_enabled ]
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    Rails.configuration.x.history_import_enabled = "true"
    @user = history_user
    @source = ListeningSource.create!(user: @user, provider: "spotify", external_account_id: "account-1", display_name: "Listener", connected_at: T)
    @file = Tempfile.new("export")
  end

  teardown do
    Rails.configuration.x.spotify_ingestion_enabled, Rails.configuration.x.history_import_enabled = @flags
    @file.close!
  end

  def event(at, track: "Song")
    ms = (at.to_f * 1000).round
    raw = Time.at(Rational(ms, 1000)).utc.iso8601(3)
    Listening::Event.new(provider: "spotify", source_event_id: ms.to_s, reported_at: Time.iso8601(raw), reported_at_raw: raw,
                         timestamp_kind: "spotify_played_at", duration_ms: 200_000, artist_name: "Band", track_name: track, album_name: "Album",
                         provider_track_id: "id-#{track}", provider_album_id: "alb", provider_artist_ids: [ "art" ], isrc: "ISRC#{track}", context: { "type" => "playlist" })
  end

  def record(*events)
    recorder = Listening::Recorder.new(@source, now: -> { T + 1.hour })
    events.each { recorder.record!(_1) }
  end

  def export!
    File.open(@file.path, "w") { Listening::ArchiveExport.new(@source).write(_1) }
  end

  # What's left is the other database: no trace of the export's plays.
  def forget_spotify!
    ReviewDecision.delete_all
    scrobbles = ListeningObservation.pluck(:scrobble_id).compact
    ListeningObservation.delete_all
    Scrobble.where(id: scrobbles, source: "spotify").delete_all
    @source.polls.delete_all
    @source.gaps.delete_all
  end

  def merge! = Listening::ArchiveMerge.new(@file.path).run!(confirm_database: ApplicationRecord.connection.current_database)

  test "new plays arrive, with their reports intact, and repeating adds nothing" do
    record(event(T), event(T + 300, track: "Other"))
    ListeningObservation.find_by!(source_event_id: event(T).source_event_id).update!(times_seen: 7)
    export!
    forget_spotify!

    assert_equal({ created: 2 }, merge!.tally.slice(:created))
    observation = ListeningObservation.find_by!(source_event_id: event(T).source_event_id)
    assert_equal 7, observation.times_seen
    assert_equal T + 1.hour, observation.received_at
    assert_equal "ISRCSong", observation.isrc
    assert_equal "Song", observation.name_variant.track_name

    assert_no_difference([ "Scrobble.count", "ListeningObservation.count" ]) do
      assert_equal 2, merge!.tally[:already_present]
    end
    assert_equal 7, observation.reload.times_seen
  end

  test "a Spotify report of a Last.fm play is linked: one play, Last.fm untouched" do
    record(event(T + 200))
    export!
    forget_spotify!
    play = scrobble(@user, at: T, variant: variant(track: "Song", artist: "Band", album: "Album"))
    before = play.attributes

    report = merge!

    assert_equal 1, report.tally[:linked]
    assert_equal before, play.reload.attributes
    assert_equal 1, Scrobble.count
    assert_equal play, ListeningObservation.sole.scrobble
    assert_equal "linked", ListeningObservation.sole.link_state
  end

  test "an ambiguous report waits for a person and is reported, never counted" do
    record(event(T + 200))
    export!
    forget_spotify!
    %w[0 1].each { |seq| scrobble(@user, at: T + seq.to_i, seq: 0, variant: variant(track: "Song", artist: "Band", album: "Album")) }

    report = assert_no_difference("Scrobble.count") { merge! }

    assert_equal 1, report.tally[:pending_review]
    assert_equal 1, report.held_for_review
  end

  test "a person's kept-separate decision carries, with its original time" do
    record(event(T + 200))
    observation = ListeningObservation.sole
    decided = T + 2.days
    ReviewDecision.create!(user: @user, subject_type: "ListeningObservation", subject_id: observation.id, action: "kept_separate",
                           source: "person", details: { "note" => "two listens" }, created_at: decided)
    export!
    forget_spotify!
    %w[0 1].each { |seq| scrobble(@user, at: T + seq.to_i, seq: 0, variant: variant(track: "Song", artist: "Band", album: "Album")) }

    report = merge!

    assert_equal 1, report.tally[:decisions_applied]
    merged = ListeningObservation.sole
    assert_equal "created", merged.link_state
    decision = ReviewDecision.find_by!(subject_id: merged.id)
    assert_equal decided, decision.created_at
    assert_equal({ "note" => "two listens" }, decision.details["carried"])
    assert_no_difference("ReviewDecision.count") { assert_equal 1, merge!.tally[:decisions_already_present] }
  end

  test "a linked decision that can't be mapped goes back to a person" do
    record(event(T + 200))
    ReviewDecision.create!(user: @user, subject_type: "ListeningObservation", subject_id: ListeningObservation.sole.id, action: "linked",
                           source: "person", created_at: T + 1.day)
    export!
    forget_spotify!

    assert_match(/decided linked there/, merge!.conflicts.sole)
  end

  test "poll and gap history carry, once" do
    record(event(T))
    poll = @source.polls.create!(user_id: @user.id, trigger: "schedule", started_at: T, finished_at: T + 1, outcome: "ok")
    @source.gaps.create!(user_id: @user.id, listening_poll: poll, gap_from: T - 1.hour, gap_to: T, detected_at: T)
    export!
    forget_spotify!

    2.times { merge! }

    assert_equal 1, @source.polls.reload.count
    assert_equal @source.polls.reload.sole, @source.gaps.reload.sole.listening_poll
  end

  test "catalogue decisions are carried in the file and reported, not applied" do
    MetadataOverride.create!(entity_kind: "artist", provider_id: "x", field: "genres", value: [])
    record(event(T))
    export!
    forget_spotify!

    assert_equal "metadata_overrides", merge!.other_decisions.sole["table"]
  end

  test "the export holds no credentials" do
    @source.update!(credentials: { "access_token" => "SECRET-ACCESS", "refresh_token" => "SECRET-REFRESH" })
    record(event(T))
    export!

    assert_not_includes File.read(@file.path), "SECRET-"
  end

  test "refuses a changed file, the wrong database, the development database and another account" do
    record(event(T))
    export!
    good = File.read(@file.path)
    name = ApplicationRecord.connection.current_database
    merge = Listening::ArchiveMerge.new(@file.path)

    assert_raises(Listening::ArchiveMerge::Refused) { merge.run!(confirm_database: "something_else") }
    connection = ApplicationRecord.connection
    connection.define_singleton_method(:current_database) { "runout_development" }
    begin
      error = assert_raises(Listening::ArchiveMerge::Refused) { merge.run!(confirm_database: "runout_development") }
      assert_match(/protected/, error.message)
    ensure
      connection.singleton_class.remove_method(:current_database)
    end

    File.write(@file.path, good.sub('"Song"', '"Sung"'))
    assert_raises(Listening::ArchiveMerge::Refused) { merge.run!(confirm_database: name) }
    File.write(@file.path, good.lines[0..-2].join)
    assert_raises(Listening::ArchiveMerge::Refused) { merge.run!(confirm_database: name) }

    File.write(@file.path, good)
    @source.update!(external_account_id: "someone-else")
    assert_raises(Listening::ArchiveMerge::Refused) { merge.run!(confirm_database: name) }
  end
end
