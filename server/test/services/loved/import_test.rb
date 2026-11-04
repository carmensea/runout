require "test_helper"

# Loved::Import against a fake Last.fm: pagination, repeats, re-loves, removals only after a complete
# list, manual rows left alone, and catalogue matching through the usual rules. Synthetic data only.
class Loved::ImportTest < ActiveSupport::TestCase
  include HistoryHelpers

  # Only the loved import's own switch is on: history storage stays off, as in production.
  setup do
    Rails.configuration.x.history_import_enabled = "false"
    @loved_flag = Rails.configuration.x.lastfm_loved_import_enabled
    Rails.configuration.x.lastfm_loved_import_enabled = "true"
    @user = history_user
    Identity.create!(user: @user, provider: Identity::LASTFM, uid: "listener", username: "listener")
  end
  teardown { Rails.configuration.x.lastfm_loved_import_enabled = @loved_flag }

  MBID = "0a1b2c3d-0000-4000-8000-00000000000%d"

  # A fake client: `lists` is the loved list per call sequence; each page holds `per_page` entries.
  class FakeClient
    attr_reader :calls

    def initialize(entries, per_page: 1000, announced: nil)
      @entries = entries
      @per_page = per_page
      @announced = announced
      @calls = 0
    end

    def loved_tracks(username:, page:, limit:)
      @calls += 1
      slice = @entries.each_slice(@per_page).to_a
      Lastfm::LovedTracksPage.parse("lovedtracks" => {
        "track" => slice[page - 1] || [],
        "@attr" => { "user" => username, "page" => page.to_s, "perPage" => @per_page.to_s, "totalPages" => [ slice.size, 1 ].max.to_s, "total" => (@announced || @entries.size).to_s }
      })
    end
  end

  def entry(track, artist, uts:, mbid: "", artist_mbid: "")
    { "name" => track, "mbid" => mbid, "url" => "https://www.last.fm/music/#{artist}/_/#{track}", "date" => { "uts" => uts.to_s },
      "artist" => { "name" => artist, "mbid" => artist_mbid } }
  end

  def import(entries, at: Time.utc(2026, 11, 4, 12), **client_options)
    client = FakeClient.new(entries, **client_options)
    [ Loved::Import.new(user: @user, client: client, now: -> { at }).run!, client ]
  end

  test "fetches every page, stores each song once with its loved date and provenance, and matches it" do
    entries = (1..3).map { |i| entry("Song #{i}", "Band", uts: 1_262_304_000 + i) }
    report, client = import(entries, per_page: 2)
    assert_equal 2, client.calls
    assert_equal [ 3, 3, 0, 0, 0 ], [ report.listed, report.added, report.kept, report.unloved, report.manual_skipped ]
    assert_equal 3, report.linked
    loved = LovedTrack.where(user: @user).order(:loved_at)
    assert_equal [ "Song 1", "Song 2", "Song 3" ], loved.map { |l| l.name_variant.track_name }
    assert_equal Time.utc(2010, 1, 1, 0, 0, 1), loved.first.loved_at
    assert_equal "lastfm", loved.first.source
    assert_equal "https://www.last.fm/music/Band/_/Song 1", loved.first.source_url
    assert_equal Time.utc(2026, 11, 4, 12), loved.first.first_imported_at
    assert_equal "", loved.first.name_variant.album_name
    assert_equal "name", loved.first.name_variant.track_match
    assert_equal 1, Artist.count
    assert_equal 3, Track.count
  end

  test "repeating the import changes nothing, and a song listed twice is stored once with its earliest date" do
    entries = [ entry("Song", "Band", uts: 1_300_000_000), entry("Song", "Band", uts: 1_200_000_000), entry("Other", "Band", uts: 1_250_000_000) ]
    import(entries)
    before = LovedTrack.order(:id).map { |l| l.attributes.except("updated_at", "last_listed_at") }
    report, = import(entries, at: Time.utc(2026, 11, 5))
    assert_equal [ 2, 0, 2, 0 ], [ report.listed, report.added, report.kept, report.unloved ]
    assert_equal before, LovedTrack.order(:id).map { |l| l.attributes.except("updated_at", "last_listed_at") }
    assert_equal Time.at(1_200_000_000).utc, LovedTrack.joins(:name_variant).find_by(name_variants: { track_name: "Song" }).loved_at
    assert_equal 2, NameVariant.count
  end

  test "a song Last.fm no longer lists is marked unloved and kept; listed again, it is loved again with the new date" do
    import([ entry("Song", "Band", uts: 1_200_000_000), entry("Gone", "Band", uts: 1_200_000_001) ])
    report, = import([ entry("Song", "Band", uts: 1_200_000_000) ], at: Time.utc(2026, 11, 5))
    assert_equal 1, report.unloved
    gone = LovedTrack.joins(:name_variant).find_by(name_variants: { track_name: "Gone" })
    assert_equal Time.utc(2026, 11, 5), gone.unloved_at
    assert_equal 1, LovedTrack.current.count
    report, = import([ entry("Song", "Band", uts: 1_200_000_000), entry("Gone", "Band", uts: 1_700_000_000) ], at: Time.utc(2026, 11, 6))
    assert_equal [ 1, 1, 0 ], [ report.reloved, report.kept, report.unloved ]
    assert_nil gone.reload.unloved_at
    assert_equal Time.at(1_700_000_000).utc, gone.loved_at
  end

  test "an incomplete list never unloves anything" do
    import([ entry("Song", "Band", uts: 1_200_000_000), entry("Other", "Band", uts: 1_200_000_001) ])
    error = assert_raises(Loved::Import::Incomplete) { import([ entry("Song", "Band", uts: 1_200_000_000) ], announced: 2, at: Time.utc(2026, 11, 5)) }
    assert_match(/announced 2 loved tracks, 1 received/, error.message)
    assert_equal 2, LovedTrack.current.count
    assert_equal [ Time.utc(2026, 11, 4, 12) ], LovedTrack.pluck(:last_listed_at).uniq
  end

  test "runout favourites and manual rows are never changed by a refresh" do
    variant = ListeningStorage.writing_for("lastfm_loved") { NameVariant.for!(artist_name: "Band", track_name: "Mine", album_name: "") }
    ListeningStorage.writing_for("lastfm_loved") do
      LovedTrack.create!(user: @user, name_variant: variant, source: "runout", loved_at: Time.utc(2026, 1, 1))
      LovedTrack.create!(user: @user, name_variant: variant, source: "lastfm", loved_at: Time.utc(2020, 1, 1), manual: true, unloved_at: Time.utc(2021, 1, 1))
    end
    report, = import([ entry("Mine", "Band", uts: 1_600_000_000) ])
    assert_equal [ 0, 1, 0 ], [ report.added, report.manual_skipped, report.unloved ]
    assert_equal Time.utc(2021, 1, 1), LovedTrack.lastfm.sole.unloved_at
    assert_equal Time.utc(2026, 1, 1), LovedTrack.find_by(source: "runout").loved_at
    assert_nil LovedTrack.find_by(source: "runout").unloved_at
  end

  test "matching follows the catalogue rules: an ID links the recording, a disputed ID is ignored, a name alone never joins an identified track" do
    Rails.configuration.x.history_import_enabled = "true"
    played = variant(track: "Song", artist: "Band", album: "LP", artist_mbid: format(MBID, 1), track_mbid: format(MBID, 2))
    Catalogue::Matcher.new.match!(played)
    identified = played.reload.track
    assert identified.mbid
    MbidDispute.create!(strings_hash: MbidDispute.hash_for("track", "Band", "Disputed"), level: "track", artist_name: "Band", title: "Disputed",
                        candidate_mbids: [ format(MBID, 3), format(MBID, 4) ], occurrences: 2, first_seen_at: Time.current, last_seen_at: Time.current)
    Rails.configuration.x.history_import_enabled = "false"

    import([ entry("Song", "Band", uts: 1, mbid: format(MBID, 2), artist_mbid: format(MBID, 1)),
             entry("Song", "Band", uts: 2),
             entry("Disputed", "Band", uts: 3, mbid: format(MBID, 3), artist_mbid: format(MBID, 1)) ])
    by_id, by_name, disputed = LovedTrack.order(:loved_at).map(&:name_variant)
    assert_equal identified.id, by_id.track_id
    assert_equal "mbid", by_id.track_match
    refute_equal identified.id, by_name.track_id
    assert_equal "name", by_name.track_match
    assert_equal [ identified.id ], by_name.catalogue_reviews.open.where(level: "track", kind: "possible_match").sole.candidate_ids
    assert_nil disputed.track.mbid
    assert_equal "name", disputed.track_match
    # Nothing about the play's own variant changed.
    assert_equal identified.id, played.reload.track_id
  end

  test "refuses to store anything while the loved import is switched off" do
    Rails.configuration.x.lastfm_loved_import_enabled = "false"
    assert_raises(ListeningStorage::DisabledError) { import([ entry("Song", "Band", uts: 1) ]) }
    assert_equal 0, LovedTrack.count
    assert_equal 0, NameVariant.count
  end
end
