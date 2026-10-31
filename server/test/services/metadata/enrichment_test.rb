require "test_helper"

# Metadata enrichment (docs/milestone-4-plan.md §5): queueing by plays, fetching through a fake
# MusicBrainz, provenance, negative results, retries, overrides, classification, and the integrity
# of the listening history. Synthetic data only; no network.
class Metadata::EnrichmentTest < ActiveSupport::TestCase
  include HistoryHelpers

  CURE = "69ee3720-a7cb-4402-b48d-a02c366f2bcf".freeze
  BAND = "11111111-1111-4111-8111-111111111111".freeze
  GONE = "22222222-2222-4222-8222-222222222222".freeze

  class FakePacer
    attr_reader :reserved, :cooled

    def initialize = (@reserved = 0) && (@cooled = [])
    def reserve! = @reserved += 1
    def cool_down!(seconds) = @cooled << seconds
  end

  setup do
    @flag = Rails.configuration.x.metadata_enrichment_enabled
    Rails.configuration.x.metadata_enrichment_enabled = "true"
    Genres::Seed.new.apply!
    @now = Time.utc(2026, 11, 1, 12)
    @user = history_user
    @pacer = FakePacer.new
    @answers = {}
    @requested = []
  end

  teardown { Rails.configuration.x.metadata_enrichment_enabled = @flag }

  def client
    MusicBrainz::Client.new(pacer: @pacer, http: lambda { |url|
      mbid = url[%r{artist/([^?]+)}, 1]
      @requested << mbid
      answer = @answers.fetch(mbid) { [ 404, "{}" ] }
      answer = answer.shift if answer.is_a?(Array) && answer.first.is_a?(Array)
      answer
    })
  end

  def enricher = Metadata::Enricher.new(client: client, clock: -> { @now })

  def artist_json(mbid, name:, type: "Group", gender: nil, genres: [], tags: [], id: mbid)
    [ 200, { id: id, name: name, "sort-name": name, type: type, gender: gender, area: { name: "United Kingdom", "iso-3166-1-codes": [ "GB" ] },
             "life-span": { begin: "1978", ended: false }, genres: genres.map { |n, c| { name: n, count: c } },
             tags: tags.map { |n, c| { name: n, count: c } } }.to_json ]
  end

  def played(artist, mbid: nil, plays: 1, name_only: false)
    v = variant(artist: artist, track: "Song #{artist}", album: "", **(mbid ? { artist_mbid: mbid } : {}))
    Catalogue::Matcher.new.match!(v)
    plays.times { |i| scrobble(@user, at: Time.utc(2014, 3, 1) + (artist.sum + i) * 60, variant: v) }
    v.reload
  end

  def history_fingerprint
    [ Scrobble.order(:id).pluck(:id, :played_at, :seq, :name_variant_id, :removed_at),
      NameVariant.order(:id).pluck(:id, :artist_name, :artist_mbid, :artist_id, :artist_match),
      Artist.order(:id).pluck(:id, :name, :mbid, :merged_into_id, :inference_id) ]
  end

  test "artists are queued most played first, by the artist at the end of their merge chain; name-only artists never" do
    played("The Cure", mbid: CURE, plays: 5)
    played("the cure", plays: 3) # a name-only twin
    Catalogue::ArtistInference.new.apply!
    played("Band", mbid: BAND, plays: 2)
    played("Nameless", plays: 9)
    assert_equal [ [ CURE, 8 ], [ BAND, 2 ] ], Metadata::Planner.played_artists
    assert_equal 1, Metadata::Planner.plan!(limit: 1, now: @now)
    assert_equal [ [ CURE, 8, "pending" ] ], MetadataTarget.pluck(:provider_id, :priority, :status)

    MetadataTarget.update_all(status: "ok", next_attempt_at: @now + 1.day)
    Metadata::Planner.plan!(now: @now)
    assert_equal [ [ CURE, "ok" ], [ BAND, "pending" ] ], MetadataTarget.order(priority: :desc).pluck(:provider_id, :status), "states are kept"
  end

  test "a found artist is stored as fetched, with licence and provenance, classified, and refreshed later" do
    played("The Cure", mbid: CURE, plays: 3)
    Metadata::Planner.plan!(now: @now)
    @answers[CURE] = artist_json(CURE, name: "The Cure", genres: [ [ "post-punk", 9 ], [ "new wave", 6 ], [ "gothic rock", 5 ] ],
                                 tags: [ [ "post-punk", 9 ], [ "seen live", 12 ], [ "british", 4 ] ])
    before = history_fingerprint
    summary = enricher.run!(limit: 10)
    assert_equal [ 1, 1, 1 ], [ summary.processed, summary.ok, summary.requests ]
    assert_equal 1, @pacer.reserved

    a = MetadataArtist.sole
    assert_equal [ "The Cure", "Group", nil, "United Kingdom", "GB", "1978", "CC0-1.0", @now ],
                 a.slice(:name, :artist_type, :gender, :area_name, :area_code, :begin_date, :core_license, :fetched_at).values
    assert_equal "https://musicbrainz.org/ws/2/artist/#{CURE}?inc=genres+tags&fmt=json", a.source_url
    assert_equal 6, MetadataTag.count, "every genre and tag kept as fetched, unmapped ones too"
    assert_equal [ "CC-BY-NC-SA-3.0" ], MetadataTag.distinct.pluck(:license)

    c = GenreClassification.sole
    refute c.unclassified
    assert_equal [ "indie-alternative", "pop", "punk-hardcore", "rock" ], c.broad.keys.sort, "post-punk gives 30% to Punk & hardcore (taxonomy.yml)"
    assert_in_delta 1.0, c.broad.values.sum, 1e-9
    assert_equal [ "gothic rock", "new wave", "post-punk" ], c.signals_used.sort, "seen live and british map to nothing and weigh nothing"

    t = MetadataTarget.sole
    assert_equal [ "ok", 0, @now + 180.days ], [ t.status, t.attempts, t.next_attempt_at ]
    assert_equal [ "ok" ], MetadataFetch.pluck(:outcome)
    assert_equal before, history_fingerprint, "enrichment never touches listening history or the catalogue"

    @now += 181.days
    @answers[CURE] = artist_json(CURE, name: "The Cure", genres: [ [ "post-punk", 10 ], [ "new wave", 6 ] ])
    enricher.run!
    changes = MetadataFetch.order(:id).last.changed_values
    assert_includes changes["added"], "genre:post-punk:10"
    assert_includes changes["removed"], "genre:gothic rock:5"
    assert_equal [ "new wave", "post-punk" ], GenreClassification.sole.signals_used.sort
  end

  test "missing and invalid IDs are cached as negative results; a merged ID records the surviving one" do
    played("Gone", mbid: GONE)
    played("The Cure", mbid: CURE)
    Metadata::Planner.plan!(now: @now)
    @answers[GONE] = [ 404, "{}" ]
    @answers[CURE] = artist_json(CURE, name: "The Cure", id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", genres: [ [ "post-punk", 1 ] ])
    enricher.run!
    gone = MetadataTarget.find_by!(provider_id: GONE)
    assert_equal [ "not_found", @now + 180.days ], [ gone.status, gone.next_attempt_at ]
    assert_equal "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", MetadataArtist.find_by!(provider_id: CURE).canonical_id

    @requested.clear
    @now += 30.days
    enricher.run!
    assert_empty @requested, "nothing is asked again before it is due"
  end

  test "rate limiting and outages back off, every process pauses, and after five tries the target waits a week" do
    played("The Cure", mbid: CURE)
    Metadata::Planner.plan!(now: @now)
    @answers[CURE] = [ 503, "", 7.0 ]
    assert_equal 1, enricher.run!.retrying
    t = MetadataTarget.sole
    assert_equal [ "pending", 1 ], [ t.status, t.attempts ]
    assert_equal @now + 60.seconds, t.next_attempt_at
    assert_equal [ 7.0 ], @pacer.cooled

    4.times do
      @now = MetadataTarget.sole.next_attempt_at
      enricher.run!
    end
    t.reload
    assert_equal [ "failed", @now + 7.days ], [ t.status, t.next_attempt_at ]
    assert_equal 5, MetadataFetch.where(outcome: "rate_limited").count
  end

  test "the owner's genre override wins and survives refreshes" do
    played("The Cure", mbid: CURE)
    Metadata::Planner.plan!(now: @now)
    @answers[CURE] = artist_json(CURE, name: "The Cure", genres: [ [ "post-punk", 3 ] ])
    enricher.run!
    MetadataOverride.create!(entity_kind: "artist", provider_id: CURE, field: "genres", value: [ { "genre" => "gothic-rock", "weight" => 1 } ])
    Genres::Classifications.recompute!([ CURE ])
    assert_equal [ "override", { "indie-alternative" => 1.0 }, { "gothic-rock" => 1.0 } ], GenreClassification.sole.slice(:basis, :broad, :sub).values

    @now += 181.days
    enricher.run!
    assert_equal "override", GenreClassification.sole.basis
    assert MetadataOverride.exists?(provider_id: CURE)
    assert_raises(ActiveRecord::RecordInvalid) { MetadataOverride.create!(entity_kind: "artist", provider_id: BAND, field: "genres", value: [ { "genre" => "nonsense", "weight" => 1 } ]) }
  end

  test "an artist with only unmapped tags is Unclassified, not guessed" do
    played("Band", mbid: BAND)
    Metadata::Planner.plan!(now: @now)
    @answers[BAND] = artist_json(BAND, name: "Band", tags: [ [ "seen live", 4 ], [ "favourites", 2 ] ])
    enricher.run!
    assert_equal [ true, { "unclassified" => 1.0 } ], GenreClassification.sole.slice(:unclassified, :broad).values
  end

  test "with enrichment off, nothing is queued or fetched" do
    played("The Cure", mbid: CURE)
    Rails.configuration.x.metadata_enrichment_enabled = "false"
    assert_raises(Metadata::Enrichment::Disabled) { Metadata::Planner.plan!(now: @now) }
    assert_raises(Metadata::Enrichment::Disabled) { enricher.run! }
    MetadataEnrichJob.perform_now
    assert_equal [ 0, 0 ], [ MetadataTarget.count, @pacer.reserved ]
  end

  test "progress counts completed, unavailable, failed and remaining artists, and the plays they cover" do
    played("The Cure", mbid: CURE, plays: 6)
    played("Band", mbid: BAND, plays: 3)
    played("Gone", mbid: GONE, plays: 1)
    Metadata::Planner.plan!(now: @now)
    @answers[CURE] = artist_json(CURE, name: "The Cure", genres: [ [ "post-punk", 1 ] ])
    @answers[GONE] = [ 404, "{}" ]
    @answers[BAND] = [ 503, "" ]
    enricher.run!
    r = Metadata::Progress.report
    assert_equal({ identified_artists: 3, queued: 3, completed: 1, unavailable: 1, failed: 0, remaining: 1, retrying: 1,
                   plays_of_identified_artists: 10, plays_enriched: 6, plays_classified: 6 }, r.except(:next_due, :artwork))
  end
end
