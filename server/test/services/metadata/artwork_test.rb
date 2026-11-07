require "test_helper"

# Album artwork (docs/milestone-4-plan.md §10.4): queueing played releases, the release's own cover
# then its release group's, references on approved hosts only, negative results, retries, the
# Overview's artwork, and the integrity of the listening history. Synthetic data only; no network.
class Metadata::ArtworkTest < ActiveSupport::TestCase
  include HistoryHelpers

  ARTIST = "69ee3720-a7cb-4402-b48d-a02c366f2bcf".freeze
  RELEASE = "11111111-1111-4111-8111-111111111111".freeze
  OTHER = "22222222-2222-4222-8222-222222222222".freeze
  GROUP = "33333333-3333-4333-8333-333333333333".freeze
  ARCHIVE = "https://archive.org/download/mbid-#{RELEASE}".freeze

  class FakePacer
    def reserve! = nil
    def cool_down!(_seconds) = nil
  end

  setup do
    @flag = Rails.configuration.x.metadata_enrichment_enabled
    Rails.configuration.x.metadata_enrichment_enabled = "true"
    @now = Time.utc(2026, 11, 1, 12)
    @user = history_user
    @covers = {}
    @releases = {}
    @requested = []
  end

  teardown { Rails.configuration.x.metadata_enrichment_enabled = @flag }

  def cover_art
    CoverArt::Client.new(pacer: FakePacer.new, http: lambda { |url|
      @requested << url
      answer = @covers.fetch(url.delete_prefix("#{CoverArt::Client::BASE}/")) { [ 404, "Not found" ] }
      answer.first.is_a?(Array) ? answer.shift : answer
    })
  end

  def musicbrainz
    MusicBrainz::Client.new(pacer: FakePacer.new, http: lambda { |url|
      @requested << url
      @releases.fetch(url[%r{release/([^?]+)}, 1]) { [ 404, "{}" ] }
    })
  end

  def enricher = Metadata::Artwork::Enricher.new(cover_art: cover_art, musicbrainz: musicbrainz, clock: -> { @now })

  def images(id, thumbnails: nil, front: true)
    thumbnails ||= { "250" => "http://#{id}.archive.org/250.jpg", "500" => "https://archive.org/#{id}-500.jpg", "1200" => "https://archive.org/#{id}-1200.jpg" }
    [ 200, { images: [ { id: id, front: front, approved: true, thumbnails: thumbnails } ] }.to_json ]
  end

  def played(album, mbid:, plays: 1, track: "Song")
    v = variant(artist: "Band", track: "#{track} #{album}", album: album, artist_mbid: ARTIST, album_mbid: mbid)
    Catalogue::Matcher.new.match!(v)
    plays.times { |i| scrobble(@user, at: Time.utc(2014, 3, 1) + (album.sum + i) * 60, variant: v) }
    v.reload
  end

  def history_fingerprint
    [ Scrobble.order(:id).pluck(:id, :played_at, :seq, :name_variant_id, :removed_at),
      NameVariant.order(:id).pluck(:id, :album_name, :album_mbid, :album_id, :album_match),
      Album.order(:id).pluck(:id, :title, :mbid, :merged_into_id) ]
  end

  test "played releases are queued most played first; albums without a release ID never" do
    played("First", mbid: RELEASE, plays: 3)
    played("Second", mbid: OTHER, plays: 5)
    v = variant(artist: "Band", track: "Loose", album: "Nameless", artist_mbid: ARTIST)
    Catalogue::Matcher.new.match!(v)
    4.times { |i| scrobble(@user, at: Time.utc(2015, 1, 1) + i * 60, variant: v) }

    assert_equal [ [ OTHER, 5 ], [ RELEASE, 3 ] ], Metadata::Artwork.played_releases
    assert_equal 1, Metadata::Artwork.plan!(limit: 1, now: @now)
    assert_equal [ [ "coverartarchive", "release", OTHER ] ], MetadataTarget.pluck(:provider, :entity_kind, :provider_id)
  end

  test "the release's own front cover is kept as a reference, upgraded to HTTPS, with provenance" do
    played("First", mbid: RELEASE, plays: 2)
    Metadata::Artwork.plan!(now: @now)
    @covers["release/#{RELEASE}"] = images("42")
    before = history_fingerprint
    summary = enricher.run!

    assert_equal [ 1, 1, 0 ], [ summary.processed, summary.found, summary.none ]
    art = MetadataArtwork.sole
    assert_equal [ RELEASE, nil, "release", "42" ], [ art.release_id, art.release_group_id, art.found_on, art.image_id ]
    assert_equal "https://42.archive.org/250.jpg", art.thumbnail_250
    assert_equal "#{CoverArt::Client::BASE}/release/#{RELEASE}", art.source_url
    assert_equal "ok", MetadataTarget.sole.status
    assert_includes (@now + Metadata::Artwork::REFRESH)..(@now + Metadata::Artwork::REFRESH + Metadata::Artwork::REFRESH_SPREAD), MetadataTarget.sole.next_attempt_at,
                    "asked about again in two years, at its own moment within the spread"
    assert_equal [ "ok" ], MetadataFetch.pluck(:outcome)
    assert_equal [ "#{CoverArt::Client::BASE}/release/#{RELEASE}" ], @requested, "no MusicBrainz request when the release has a cover"
    assert_equal before, history_fingerprint

    # The report: one eligible release, queued, covered this week; nothing due, nothing refreshing.
    report = Metadata::Progress.artwork(now: @now + 1.hour)
    assert_equal({ eligible: 1, queued: 1, not_queued: 0, with_cover: 1, on_release: 1, on_release_group: 0, without_cover: 0, waiting: 0,
                   in_backoff: 0, failed: 0, due_now: 0, refresh_due_30d: 0, new_covers_7d: 1, refreshed_7d: 0, fetch_problems_7d: 0, inferred: {} },
                 report.except(:last_fetch_at))
    assert_equal @now, report[:last_fetch_at]
    assert_equal 1, Metadata::Progress.artwork(now: MetadataTarget.sole.next_attempt_at - 29.days)[:refresh_due_30d], "the refresh is visible a month ahead"

    # Planning again, with a wider limit, leaves the finished release exactly as it was: no refetch.
    settled = MetadataTarget.sole.attributes.slice("status", "next_attempt_at", "attempts")
    Metadata::Artwork.plan!(limit: 1000, now: @now + 7.days)
    assert_equal settled, MetadataTarget.sole.reload.attributes.slice("status", "next_attempt_at", "attempts")
    assert_equal 0, enricher.run!.processed, "nothing due"
  end

  test "a played release that was never queued shows up as outstanding work" do
    played("First", mbid: RELEASE)
    played("Second", mbid: OTHER)
    Metadata::Artwork.plan!(limit: 1, now: @now)
    report = Metadata::Progress.artwork(now: @now)
    assert_equal [ 2, 1, 1, 1, 1, 0 ], report.values_at(:eligible, :queued, :not_queued, :due_now, :waiting, :in_backoff)
  end

  test "the report tells a release in backoff from one waiting, one without a cover and one given up" do
    played("First", mbid: RELEASE)
    played("Second", mbid: OTHER)
    Metadata::Artwork.plan!(now: @now)
    @covers["release/#{RELEASE}"] = [ 503, "" ]
    @releases[RELEASE] = [ 503, "" ]
    @releases[OTHER] = [ 200, { id: OTHER, "release-group": { id: GROUP } }.to_json ]
    enricher.run!
    report = Metadata::Progress.artwork(now: @now)
    assert_equal [ 0, 1, 1, 0, 0 ], report.values_at(:waiting, :in_backoff, :without_cover, :failed, :due_now)
    MetadataTarget.find_by(provider_id: RELEASE).update!(status: "failed", attempts: 0)
    assert_equal [ 0, 0, 1, 1 ], Metadata::Progress.artwork(now: @now).values_at(:waiting, :in_backoff, :without_cover, :failed)
  end

  test "without a cover of its own, the release group's is used, found through MusicBrainz, and both IDs are kept apart" do
    played("First", mbid: RELEASE)
    Metadata::Artwork.plan!(now: @now)
    @releases[RELEASE] = [ 200, { id: RELEASE, title: "First", "release-group": { id: GROUP, title: "First" } }.to_json ]
    @covers["release-group/#{GROUP}"] = images("77")
    enricher.run!

    art = MetadataArtwork.sole
    assert_equal [ RELEASE, GROUP, "release_group", "77" ], [ art.release_id, art.release_group_id, art.found_on, art.image_id ]
    assert_equal "#{CoverArt::Client::BASE}/release-group/#{GROUP}", art.source_url
    assert_equal [ "#{CoverArt::Client::BASE}/release/#{RELEASE}", "#{MusicBrainz::Client::BASE}/release/#{RELEASE}?inc=artist-credits+release-groups&fmt=json",
                   "#{CoverArt::Client::BASE}/release-group/#{GROUP}" ], @requested
  end

  test "no cover anywhere is cached as a negative result for months, with no image" do
    played("First", mbid: RELEASE)
    Metadata::Artwork.plan!(now: @now)
    @releases[RELEASE] = [ 200, { id: RELEASE, "release-group": { id: GROUP } }.to_json ]
    summary = enricher.run!

    assert_equal 1, summary.none
    art = MetadataArtwork.sole
    assert_nil art.found_on
    assert_nil art.thumbnail_250
    assert_equal [ "not_found", @now + Metadata::Artwork::NEGATIVE ], MetadataTarget.sole.then { |t| [ t.status, t.next_attempt_at ] }
    assert_equal 0, enricher.run!.processed, "not asked again until it is due"
  end

  test "images on other hosts are never kept, and a redirect to one is refused" do
    played("First", mbid: RELEASE)
    played("Second", mbid: OTHER)
    Metadata::Artwork.plan!(now: @now)
    @covers["release/#{RELEASE}"] = images("9", thumbnails: { "250" => "https://evil.example.com/a.jpg", "500" => "https://archive.org.example.com/b.jpg" })
    @covers["release/#{OTHER}"] = [ 307, "", "https://evil.example.com/index.json" ]
    summary = enricher.run!

    art = MetadataArtwork.find_by!(release_id: RELEASE)
    assert_equal "release", art.found_on
    assert_nil art.thumbnail_250
    assert_nil art.thumbnail_500
    assert_equal 1, summary.retrying
    assert_nil MetadataArtwork.find_by(release_id: OTHER)
    assert_match(/unapproved host/, MetadataTarget.find_by!(provider_id: OTHER).last_error)
  end

  test "a busy archive is retried with backoff, then given up on for a week" do
    played("First", mbid: RELEASE)
    Metadata::Artwork.plan!(now: @now)
    @covers["release/#{RELEASE}"] = [ 503, "busy", nil, 2.0 ]
    Metadata::Artwork::MAX_ATTEMPTS.times do |i|
      assert_equal 1, enricher.run!.processed
      target = MetadataTarget.sole
      @now = target.next_attempt_at
      assert_equal "failed", target.status if i == Metadata::Artwork::MAX_ATTEMPTS - 1
    end
    assert_equal 0, MetadataArtwork.count
  end

  test "artwork stays off with enrichment" do
    Rails.configuration.x.metadata_enrichment_enabled = nil
    assert_raises(Metadata::Enrichment::Disabled) { Metadata::Artwork.plan!(now: @now) }
    assert_raises(Metadata::Enrichment::Disabled) { enricher.run! }
  end

  test "the Overview shows covers for albums and their tracks, and counts the albums without one" do
    played("First", mbid: RELEASE, plays: 3)
    played("Second", mbid: OTHER, plays: 2)
    MetadataArtwork.create!(provider: "coverartarchive", release_id: RELEASE, found_on: "release", image_id: "1",
                            thumbnail_250: "https://archive.org/1-250.jpg", source_url: "#{CoverArt::Client::BASE}/release/#{RELEASE}", fetched_at: @now)
    MetadataArtwork.create!(provider: "coverartarchive", release_id: OTHER, source_url: "#{CoverArt::Client::BASE}/release/#{OTHER}", fetched_at: @now)
    period = Analytics::Period.parse("all", time_zone: "UTC", today: Date.new(2026, 1, 1))
    data = Analytics::Overview.new(user: @user, period: period).call

    assert_equal({ "First" => "https://archive.org/1-250.jpg", "Second" => nil }, data[:top][:albums].to_h { |a| [ a[:name], a[:imageUrl] ] })
    assert_equal({ "Song First" => "https://archive.org/1-250.jpg", "Song Second" => nil }, data[:top][:tracks].to_h { |t| [ t[:name], t[:imageUrl] ] })
    assert_equal [ nil ], data[:top][:artists].map { |a| a[:imageUrl] }
    assert_equal [ 2, 1 ], [ data[:stats][:uniqueAlbums], data[:stats][:albumsWithoutArtwork] ]
  end
end
