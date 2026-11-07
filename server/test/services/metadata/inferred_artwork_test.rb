require "test_helper"

# Artwork inferred from ListenBrainz's MBID mapping for albums and tracks without a catalogue
# release id (docs/milestone-4-plan.md §14): consensus per user and Overview key, MusicBrainz's
# record of the release must credit the same artist and carry the same title, verified covers win,
# nothing in the catalogue changes, and one user's inference never reaches another. Fictional
# names and ids only; no network.
class Metadata::InferredArtworkTest < ActiveSupport::TestCase
  include HistoryHelpers

  R1 = "aaaaaaaa-1111-4111-8111-111111111111".freeze
  R2 = "bbbbbbbb-2222-4222-8222-222222222222".freeze
  G1 = "cccccccc-3333-4333-8333-333333333333".freeze
  T = Time.utc(2026, 11, 6, 12)

  class FakePacer
    def reserve! = nil
    def cool_down!(_seconds) = nil
  end

  setup do
    @flags = %i[metadata_enrichment_enabled listenbrainz_ingestion_enabled].to_h { |f| [ f, Rails.configuration.x.public_send(f) ] }
    @flags.each_key { |f| Rails.configuration.x.public_send("#{f}=", "true") }
    @user = history_user("dana")
    @source = lb_source(@user, "dana_lb")
    @releases = { R1 => release_json("Winter Hymns", "Lantern Choir", G1), R2 => release_json("Winter Hymns", "Lantern Choir", G1) }
    @covers = { "release/#{R1}" => images("7"), "release/#{R2}" => images("8") }
    @requested = []
  end

  teardown { @flags.each { |f, v| Rails.configuration.x.public_send("#{f}=", v) } }

  def lb_source(user, name) = ListeningSource.create!(user: user, provider: "listenbrainz", external_account_id: name, display_name: name, connected_at: T)
  def release_json(title, artist, group) = [ 200, { id: "x", title: title, "artist-credit": [ { name: artist, joinphrase: "" } ], "release-group": { id: group } }.to_json ]
  def images(id) = [ 200, { images: [ { id: id, front: true, approved: true, thumbnails: { "250" => "https://archive.org/#{id}-250.jpg" } } ] }.to_json ]

  # A ListenBrainz listen as the poller records it, with ListenBrainz's mapping as context.
  def listen(source, at, track:, artist: "Lantern Choir", album: "Winter Hymns", release: R1, recording: nil)
    mapping = release && { "release_mbid" => release, "recording_mbid" => recording || "dddddddd-4444-4444-8444-#{at.to_i.to_s.rjust(12, '0')}" }
    event = Listening::Event.new(provider: "listenbrainz", source_event_id: "#{at.to_i}:#{track}", reported_at: at, reported_at_raw: at.to_i.to_s,
                                 timestamp_kind: "listen_started_at", duration_ms: 200_000, artist_name: artist, track_name: track, album_name: album,
                                 provider_track_id: nil, provider_album_id: nil, provider_artist_ids: [], isrc: nil,
                                 context: { "submission_client" => "Pano Scrobbler", "mbid_mapping" => mapping }.compact)
    Listening::Recorder.new(source, now: -> { at + 1.hour }).record!(event)
  end

  def enricher
    musicbrainz = MusicBrainz::Client.new(pacer: FakePacer.new, http: lambda { |url|
      @requested << url
      @releases.fetch(url[%r{release/([^?]+)}, 1]) { [ 404, "{}" ] }
    })
    cover_art = CoverArt::Client.new(pacer: FakePacer.new, http: lambda { |url|
      @requested << url
      answer = @covers.fetch(url.delete_prefix("#{CoverArt::Client::BASE}/")) { [ 404, "Not found" ] }
      answer.first.is_a?(Array) ? answer.shift : answer
    })
    Metadata::InferredArtwork::Enricher.new(cover_art: cover_art, musicbrainz: musicbrainz, clock: -> { T })
  end

  def plan(user = @user) = Metadata::InferredArtwork.plan!(user, now: T)
  def overview(user) = Analytics::Overview.new(user: user, period: Analytics::Period.parse("all", time_zone: "UTC", today: Date.new(2026, 11, 7))).call
  def covers(user, kind) = overview(user)[:top][kind].to_h { |x| [ x[:name], x[:imageUrl] ] }

  def catalogue_fingerprint
    [ Scrobble.order(:id).pluck(:id, :played_at, :name_variant_id), NameVariant.order(:id).pluck(:id, :artist_name, :album_name, :album_mbid, :album_id, :album_match, :track_id),
      Album.order(:id).pluck(:id, :title, :mbid, :merged_into_id), CatalogueReview.count ]
  end

  test "a consistent mapping gives the album and its tracks a cover for this user, and nothing in the catalogue changes" do
    listen(@source, T, track: "Snow")
    listen(@source, T + 1.hour, track: "Snow")
    listen(@source, T + 2.hours, track: "Thaw")
    assert_nil Album.find_by(title: "Winter Hymns").mbid, "a name-only album"
    before = catalogue_fingerprint

    assert_equal [ 1, 0, 1, 0 ], plan.to_h.values_at(:candidates, :conflicts, :queued, :withdrawn)
    row = InferredArtwork.sole
    assert_equal [ "pending", R1, 3, "album" ], [ row.status, row.release_id, row.observations, row.evidence["subject"] ]

    summary = enricher.run!
    assert_equal [ 1, 1, 0, 0 ], [ summary.processed, summary.found, summary.none, summary.mismatch ]
    assert_equal [ "#{MusicBrainz::Client::BASE}/release/#{R1}?inc=artist-credits+release-groups&fmt=json", "#{CoverArt::Client::BASE}/release/#{R1}" ], @requested
    row.reload
    assert_equal [ "ok", "Winter Hymns", "Lantern Choir", "release" ], [ row.status, row.evidence["release_title"], row.evidence["artist_credit"], row.evidence["found_on"] ]
    art = MetadataArtwork.sole
    assert_equal [ R1, "release", "7" ], [ art.release_id, art.found_on, art.image_id ]
    assert_equal "listenbrainz_mapping", MetadataFetch.sole.changed_values["via"]

    assert_equal({ "Winter Hymns" => "https://archive.org/7-250.jpg" }, covers(@user, :albums))
    assert_equal({ "Snow" => "https://archive.org/7-250.jpg", "Thaw" => "https://archive.org/7-250.jpg" }, covers(@user, :tracks))
    assert_equal [ nil ], overview(@user)[:top][:artists].map { |a| a[:imageUrl] }, "artists keep their initials"
    assert_equal 0, overview(@user)[:stats][:albumsWithoutArtwork]
    assert_equal before, catalogue_fingerprint
    assert_nil Album.find_by(title: "Winter Hymns").reload.mbid, "the mapping never becomes the album's id"

    assert_equal [ 1, 0, 0, 0 ], plan.to_h.values_at(:candidates, :conflicts, :queued, :withdrawn), "settled: not asked again"
    assert_equal 0, enricher.run!.processed
  end

  test "listens that disagree about the release keep the placeholder; a later disagreement withdraws a cover" do
    listen(@source, T, track: "Snow", release: R1)
    listen(@source, T + 1.hour, track: "Thaw", release: R2)
    assert_equal [ 0, 1, 0, 0 ], plan.to_h.values_at(:candidates, :conflicts, :queued, :withdrawn)
    assert_equal 0, InferredArtwork.count
    assert_equal({ "Winter Hymns" => nil }, covers(@user, :albums))

    other = history_user("erin")
    other_source = lb_source(other, "erin_lb")
    listen(other_source, T, track: "Snow", release: R1)
    plan(other)
    enricher.run!
    assert_equal({ "Winter Hymns" => "https://archive.org/7-250.jpg" }, covers(other, :albums))
    listen(other_source, T + 1.day, track: "Thaw", release: R2)
    assert_equal [ 0, 1, 0, 1 ], plan(other).to_h.values_at(:candidates, :conflicts, :queued, :withdrawn)
    assert_equal({ "Winter Hymns" => nil }, covers(other, :albums), "withdrawn")
  end

  test "a listen without a mapping is no candidate, and an id that isn't one is ignored" do
    listen(@source, T, track: "Snow", release: nil)
    listen(@source, T + 1.hour, track: "Thaw", release: "not-an-mbid")
    assert_equal [ 0, 0, 0, 0 ], plan.to_h.values_at(:candidates, :conflicts, :queued, :withdrawn)
  end

  test "a release MusicBrainz credits to another artist, or titles differently, is a mismatch: no cover, nothing fetched" do
    listen(@source, T, track: "Snow")
    @releases[R1] = release_json("Winter Hymns", "Someone Else", G1)
    plan
    assert_equal 1, enricher.run!.mismatch
    assert_equal [ "mismatch", "Someone Else" ], InferredArtwork.sole.then { |r| [ r.status, r.evidence["artist_credit"] ] }
    assert_equal 0, MetadataArtwork.count
    assert_equal({ "Winter Hymns" => nil }, covers(@user, :albums))

    @releases[R1] = release_json("Winter Hymns (Deluxe Edition)", "Lantern Choir", G1)
    InferredArtwork.sole.update!(status: "pending")
    assert_equal 1, enricher.run!.mismatch
  end

  test "one user's inference never reaches another: each account's own listens, each account's own cover" do
    erin = history_user("erin")
    erin_source = lb_source(erin, "erin_lb")
    lastfm_only = history_user("fay")
    listen(@source, T, track: "Snow", release: R1)
    listen(erin_source, T + 1.hour, track: "Snow", release: R2)
    scrobble(lastfm_only, at: T + 2.hours, variant: variant(track: "Snow", artist: "Lantern Choir", album: "Winter Hymns"))
    assert_equal 1, Album.where(title: "Winter Hymns").count, "one name-only album, shared by all three"

    assert_equal [ 1, 0 ], plan(@user).to_h.values_at(:candidates, :conflicts), "Erin's listen is not Dana's evidence"
    assert_equal [ 1, 0 ], plan(erin).to_h.values_at(:candidates, :conflicts)
    assert_equal [ 1, 1 ], InferredArtwork.where(user: @user).pluck(:observations) + InferredArtwork.where(user: erin).pluck(:observations)
    assert_equal 2, enricher.run!.found
    assert_equal({ "Winter Hymns" => "https://archive.org/7-250.jpg" }, covers(@user, :albums))
    assert_equal({ "Winter Hymns" => "https://archive.org/8-250.jpg" }, covers(erin, :albums))
    assert_equal({ "Winter Hymns" => nil }, covers(lastfm_only, :albums), "no inference without ListenBrainz evidence of one's own")
    assert_equal [ 1, 0 ], [ overview(lastfm_only)[:stats][:albumsWithoutArtwork], overview(@user)[:stats][:albumsWithoutArtwork] ]
  end

  test "repeated listens count as evidence for one row; a cover already on file for the release is reused without a fetch" do
    4.times { |i| listen(@source, T + i.hours, track: "Snow") }
    MetadataArtwork.create!(provider: "coverartarchive", release_id: R1, found_on: "release", image_id: "9",
                            thumbnail_250: "https://archive.org/9-250.jpg", source_url: "#{CoverArt::Client::BASE}/release/#{R1}", fetched_at: T)
    plan
    assert_equal [ 4, 1 ], [ InferredArtwork.sole.observations, InferredArtwork.count ]
    assert_equal 1, enricher.run!.found
    assert_equal [ "#{MusicBrainz::Client::BASE}/release/#{R1}?inc=artist-credits+release-groups&fmt=json" ], @requested, "MusicBrainz only: the cover was on file"
    assert_equal({ "Winter Hymns" => "https://archive.org/9-250.jpg" }, covers(@user, :albums))
  end

  test "a verified cover for the catalogue release wins over an inferred one" do
    listen(@source, T, track: "Snow")
    plan
    enricher.run!
    assert_equal({ "Winter Hymns" => "https://archive.org/7-250.jpg" }, covers(@user, :albums))

    Album.find_by(title: "Winter Hymns").update!(mbid: R2)
    MetadataArtwork.create!(provider: "coverartarchive", release_id: R2, found_on: "release", image_id: "8",
                            thumbnail_250: "https://archive.org/8-250.jpg", source_url: "#{CoverArt::Client::BASE}/release/#{R2}", fetched_at: T)
    assert_equal({ "Winter Hymns" => "https://archive.org/8-250.jpg" }, covers(@user, :albums))
    assert_equal({ "Snow" => "https://archive.org/8-250.jpg" }, covers(@user, :tracks))
  end

  test "a track with no album name gets a cover of its own from a consistent mapping, without an album being invented" do
    listen(@source, T, track: "Loose Song", album: "")
    listen(@source, T + 1.hour, track: "Loose Song", album: "")
    assert_equal [ 1, 0, 1 ], plan.to_h.values_at(:candidates, :conflicts, :queued)
    assert_equal "track", InferredArtwork.sole.evidence["subject"]
    assert_equal 1, enricher.run!.found
    assert_equal({ "Loose Song" => "https://archive.org/7-250.jpg" }, covers(@user, :tracks))
    assert_empty covers(@user, :albums)
    assert_equal 0, Album.count
  end

  test "a busy archive is retried with backoff and given up on after five tries; the flag gates everything" do
    listen(@source, T, track: "Snow")
    plan
    @covers["release/#{R1}"] = [ 503, "" ]
    @covers["release-group/#{G1}"] = [ 503, "" ]
    assert_equal 1, enricher.run!.retrying
    assert_equal [ "pending", 1, T + 60 ], InferredArtwork.sole.then { |r| [ r.status, r.attempts, r.next_attempt_at ] }
    assert_equal 0, enricher.run!.processed, "waiting out the backoff"
    InferredArtwork.sole.update!(attempts: 4, next_attempt_at: nil)
    assert_equal 1, enricher.run!.failed
    assert_equal [ "failed", T + Metadata::InferredArtwork::FAILED_RETRY ], InferredArtwork.sole.then { |r| [ r.status, r.next_attempt_at ] }

    Rails.configuration.x.metadata_enrichment_enabled = "false"
    assert_raises(Metadata::Enrichment::Disabled) { plan }
    assert_raises(Metadata::Enrichment::Disabled) { enricher.run! }
  end
end
