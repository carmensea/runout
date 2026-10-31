require "test_helper"

# An artist name without a MusicBrainz ID joins the one identified artist with that name, when
# nothing contradicts it (Catalogue::ArtistInference). Synthetic data only.
class Catalogue::ArtistInferenceTest < ActiveSupport::TestCase
  include HistoryHelpers

  CURE = "69ee3720-a7cb-4402-b48d-a02c366f2bcf".freeze
  OTHER = "11111111-1111-4111-8111-111111111111".freeze
  ALBUM = "33333333-3333-4333-8333-333333333333".freeze
  TRACK = "44444444-4444-4444-8444-444444444444".freeze

  setup do
    @user = history_user
    @user.update!(reporting_timezone: "UTC")
    @matcher = Catalogue::Matcher.new
    @inference = Catalogue::ArtistInference.new
    @at = Time.utc(2014, 3, 1)
  end

  def matched(artist: "The Cure", track: "Lovesong", album: "Disintegration", **mbids)
    variant(artist: artist, track: track, album: album, **mbids).tap { |v| @matcher.match!(v) }.reload
  end

  def plays(v, count = 1)
    count.times { @at += 60; scrobble(@user, at: @at, variant: v) }
    v
  end

  # The state the real import left: a name-only "The Cure" created before the identified one, with a
  # possible-match review once both exist.
  def twins
    name_only = plays(matched(artist: "the cure", track: "Pictures of You"), 3)
    identified = plays(matched(artist: "The Cure", track: "Lovesong", artist_mbid: CURE), 5)
    @matcher.match!(name_only)
    [ name_only.reload, identified ]
  end

  def candidate_for(name = "the cure") = @inference.candidates.find { |c| c.normalized_name == name }

  def overview = Analytics::Overview.new(user: @user, period: Analytics::Period.parse("all", time_zone: "UTC")).call

  def stored = Scrobble.order(:id).pluck(:id, :played_at, :seq, :name_variant_id)

  test "a new variant without an artist ID joins the one identified artist with its name" do
    cure = matched(artist_mbid: CURE)
    later = matched(artist: "THE CURE", track: "Lullaby")
    assert_equal [ cure.artist_id, "inferred" ], [ later.artist_id, later.artist_match ]
    assert_empty later.catalogue_reviews
    inference = CatalogueInference.sole
    assert_equal [ "the cure", cure.artist_id, nil, "applied" ], inference.slice(:normalized_name, :into_id, :from_id, :state).values
    assert_equal Track.find(later.track_id).artist_id, cure.artist_id, "its track is under the same artist"
  end

  test "an existing name-only twin is merged into the identified artist, and counts as one" do
    name_only, identified = twins
    twin = name_only.artist
    assert_equal [ "name", nil ], [ name_only.artist_match, twin.mbid ]
    review = name_only.catalogue_reviews.sole
    before_overview = overview
    assert_equal 2, before_overview[:stats][:uniqueArtists]
    before = stored

    candidate = candidate_for
    assert candidate.eligible?
    assert_equal [ twin.id, identified.artist_id, 3 ], [ candidate.from.id, candidate.into.id, candidate.plays ]
    @inference.apply!

    inference = CatalogueInference.sole
    assert_equal [ identified.artist_id, twin.id ], [ twin.reload.merged_into_id, inference.from_id ]
    assert_equal inference.id, twin.inference_id
    assert_equal [ identified.artist_id, "inferred" ], [ name_only.reload.artist_id, name_only.artist_match ]
    assert_equal [ "resolved", identified.artist_id, inference.id, nil ], review.reload.slice(:state, :chosen_id, :inference_id, :decided_by_id).values
    assert_empty CatalogueReview.open.where(level: "artist")
    assert_equal [ review.id ], inference.evidence["reviews"]

    o = overview
    assert_equal 1, o[:stats][:uniqueArtists]
    assert_equal [ [ "a#{identified.artist_id}", "The Cure", 8 ] ], o[:top][:artists].map { |a| a.values_at(:id, :name, :scrobbles) }
    assert_equal before_overview[:discovery][:firstHeard].first[:firstScrobble], o[:discovery][:firstHeard].first[:firstScrobble],
                 "first heard is the twin's earlier play"
    assert_equal before, stored, "no scrobble changes"
    assert_equal [ "the cure", nil ], NameVariant.find(name_only.id).slice(:artist_name, :artist_mbid).values, "strings and IDs kept"
  end

  test "the twin's name-only albums and tracks join the same-titled ones; releases and recordings with IDs stay apart" do
    plays(matched(artist: "the cure", track: "Lovesong", album: "Disintegration"))
    with_ids = plays(matched(artist: "the cure", track: "Plainsong", album: "Disintegration (Deluxe)", album_mbid: ALBUM, track_mbid: TRACK))
    cure = plays(matched(artist: "The Cure", track: "Lovesong", album: "Disintegration", artist_mbid: CURE))
    name_only_album = NameVariant.find_by!(artist_name: "the cure", track_name: "Lovesong").album
    refute_equal name_only_album.id, cure.album_id, "two name-only Disintegrations, one per artist, before"

    @inference.apply!
    v = NameVariant.find_by!(artist_name: "the cure", track_name: "Lovesong")
    assert_equal [ cure.album_id, cure.track_id ], [ v.album.resolved.id, v.track.resolved.id ]
    assert_equal %w[name name], [ v.album_match, v.track_match ]
    assert_equal [ ALBUM, TRACK ], [ with_ids.reload.album.mbid, with_ids.track.mbid ], "the release and recording are untouched"
    assert_nil with_ids.album.merged_into_id
    assert_equal cure.artist_id, with_ids.album.artist.resolved.id, "consistent with its artist through the merge"
    assert_equal({ albums: 2, tracks: 2 }, { albums: overview[:top][:totals][:albums], tracks: overview[:stats][:uniqueTracks] })
  end

  test "several identified artists with the name: nothing is inferred" do
    us = matched(artist: "Nirvana", artist_mbid: CURE)
    uk = matched(artist: "Nirvana", artist_mbid: OTHER)
    unknown = matched(artist: "nirvana")
    assert_equal "name", unknown.artist_match
    assert_equal [ us.artist_id, uk.artist_id ].sort, unknown.catalogue_reviews.sole.candidate_ids
    assert_equal "several identified artists have this name", candidate_for("nirvana").excluded
    @inference.apply!
    assert_equal 0, CatalogueInference.count
  end

  test "a recording or release by another identified artist is evidence against the match" do
    other = matched(artist: "Robert Smith", track: "Pictures of You", track_mbid: TRACK, artist_mbid: OTHER)
    plays(matched(artist: "the cure", track: "Pictures of You", track_mbid: TRACK))
    plays(matched(artist: "The Cure", artist_mbid: CURE))
    assert_equal "a recording or release among its plays belongs to another artist", candidate_for.excluded
    assert other.artist_id

    later = matched(artist: "THE CURE", track: "Pictures of You", track_mbid: TRACK)
    assert_equal "name", later.artist_match, "a new variant with that evidence isn't inferred either"
  end

  test "a release owned by another artist's name-only twin is evidence too, whatever order inferences apply in" do
    # Classixx exists twice, like The Cure; a release among the Cure twin's plays belongs to Classixx's
    # name-only twin. Classixx would join its identified artist, so the release is evidence already.
    plays(matched(artist: "classixx", track: "Holding On", album: "Chapter One", album_mbid: ALBUM))
    plays(matched(artist: "Classixx", track: "All You're Waiting For", artist_mbid: OTHER))
    plays(matched(artist: "the cure", track: "Lovesong (Classixx Remix)", album: "Chapter One", album_mbid: ALBUM))
    plays(matched(artist: "The Cure", artist_mbid: CURE))
    @matcher.match_pending!

    assert_equal "a recording or release among its plays belongs to another artist", candidate_for.excluded
    assert candidate_for("classixx").eligible?
    @inference.apply!
    assert_equal [ "classixx" ], CatalogueInference.pluck(:normalized_name), "the dry run said exactly what applying did"
  end

  test "a curated alias, a manual link or a dismissed review keeps the twin apart" do
    name_only, = twins
    ArtistAlias.create!(artist: Artist.create!(name: "Cure, The"), name: "the cure", source: "manual")
    assert_equal "a curated alias names it", candidate_for.excluded
    ArtistAlias.delete_all

    Catalogue::Decisions.dismiss!(name_only.catalogue_reviews.sole, by: @user)
    assert_equal "a person dismissed the match", candidate_for.excluded
    CatalogueReview.update_all(state: "superseded")

    Catalogue::Decisions.assign!(name_only, :artist, name_only.artist, by: @user)
    assert_equal "a person linked its plays by hand", candidate_for.excluded
    @inference.apply!
    assert_equal [ "manual", nil ], [ name_only.reload.artist_match, name_only.artist.mbid ]
  end

  test "merge chains are respected: identified artists merged by a person count once; a person's merge of the twin stands" do
    first = matched(artist: "Low", artist_mbid: CURE)
    second = matched(artist: "Low", artist_mbid: OTHER, track: "Words")
    Catalogue::Decisions.merge!(second.artist, first.artist, by: @user)
    later = matched(artist: "low", track: "Lullaby")
    assert_equal [ first.artist_id, "inferred" ], [ later.artist_id, later.artist_match ], "one identified artist after the merge"

    name_only, identified = twins
    Catalogue::Decisions.merge!(name_only.artist, identified.artist, by: @user)
    assert_nil candidate_for, "already merged by a person: listed nowhere"
    assert_equal "manual", name_only.reload.artist_match
    assert_nil name_only.artist.inference_id
  end

  test "several name-only artists with the name (a person split them) aren't inferred" do
    twins
    Artist.create!(name: "The Cure")
    assert_equal "several name-only artists have this name", candidate_for.excluded
  end

  test "a disputed artist ID is evidence against the match" do
    name_only, = twins
    MbidDispute.record!([ HistoryImport::Snapshot::IdConflict.new(level: "artist", artist_name: "the cure", title: nil, played_at: @at, mbids: [ CURE ]) ],
                        window: window(@user, from: Time.utc(2014, 3, 1), to: Time.utc(2014, 4, 1)))
    @matcher.match!(name_only)
    assert_equal "its artist ID is disputed", candidate_for.excluded
  end

  test "applying is idempotent" do
    twins
    @inference.apply!
    state = [ CatalogueInference.pluck(:id), NameVariant.order(:id).pluck(:artist_id, :artist_match), Artist.order(:id).pluck(:merged_into_id) ]
    @inference.apply!
    assert_equal state, [ CatalogueInference.pluck(:id), NameVariant.order(:id).pluck(:artist_id, :artist_match), Artist.order(:id).pluck(:merged_into_id) ]
    assert_empty @inference.candidates
  end

  test "an inference can be reverted, which restores the twin and its review, and isn't made again" do
    name_only, identified = twins
    before = stored
    @inference.apply!
    inference = CatalogueInference.sole
    @inference.revert!(inference)

    assert_equal [ "reverted", nil ], [ inference.state, name_only.artist.reload.merged_into_id ]
    assert inference.reverted_at
    assert_equal [ name_only.artist_id, "name" ], [ name_only.reload.artist_id, name_only.artist_match ]
    assert_equal %w[open resolved], name_only.catalogue_reviews.order(:id).pluck(:state).sort, "the old resolution stays on record"
    assert_equal 2, overview[:stats][:uniqueArtists]
    assert_equal before, stored

    assert_equal "this inference was reverted before", candidate_for.excluded
    @inference.apply!
    assert_equal 1, CatalogueInference.count
    later = matched(artist: "THE CURE", track: "Lullaby")
    refute_equal identified.artist_id, later.artist_id, "new variants aren't inferred either"
  end

  test "with history storage off, inference is refused" do
    twins
    Rails.configuration.x.history_import_enabled = "false"
    assert_raises(HistoryImport::DisabledError) { @inference.apply! }
    assert_equal 0, CatalogueInference.count
  end
end
