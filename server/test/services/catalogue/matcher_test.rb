require "test_helper"

# Stage 2.5: canonical matching. Synthetic names and IDs only.
class Catalogue::MatcherTest < ActiveSupport::TestCase
  include HistoryHelpers

  NIRVANA_US = "5b11f4ce-a62d-471e-81fc-a69a8278c7da".freeze
  NIRVANA_UK = "9282c8b4-ca0b-4c6b-b7e3-4f7762dfc4d6".freeze
  BEATLES = "b10bbbfc-cf9e-42e0-be17-e2c3e1d2600d".freeze
  REC_1 = "11111111-1111-4111-8111-111111111111".freeze
  REC_2 = "22222222-2222-4222-8222-222222222222".freeze
  REL_1 = "33333333-3333-4333-8333-333333333333".freeze
  REL_2 = "44444444-4444-4444-8444-444444444444".freeze

  setup do
    @matcher = Catalogue::Matcher.new
    @reviewer = history_user("reviewer")
  end

  def v(artist: "Artist", track: "Track", album: "", **mbids) = variant(artist: artist, track: track, album: album, **mbids)

  def matched(**fields)
    variant = v(**fields)
    @matcher.match!(variant)
    variant.reload
  end

  def levels(variant) = [ variant.artist_match, variant.album_match, variant.track_match ]

  test "a MusicBrainz ID links variants spelled differently to one artist" do
    a = matched(artist: "The Beatles", artist_mbid: BEATLES)
    b = matched(artist: "Beatles", artist_mbid: BEATLES.upcase)
    assert_equal "mbid", a.artist_match
    assert_equal a.artist_id, b.artist_id
    assert_equal [ "The Beatles", BEATLES ], [ a.artist.name, a.artist.mbid ]
    assert_equal "Beatles", b.artist_name, "the variant keeps its exact strings"
    assert_equal BEATLES.upcase, b.artist_mbid
  end

  test "an invalid or blank MusicBrainz ID is treated as missing" do
    a = matched(artist: "Artist", artist_mbid: "not-an-mbid")
    b = matched(artist: "Artist", artist_mbid: "")
    assert_equal [ "name", "name" ], [ a.artist_match, b.artist_match ]
    assert_equal a.artist_id, b.artist_id
    assert_nil a.artist.mbid
  end

  test "artists sharing a name stay apart, and a name alone never joins an identified one" do
    us = matched(artist: "Nirvana", artist_mbid: NIRVANA_US)
    uk = matched(artist: "Nirvana", artist_mbid: NIRVANA_UK)
    unknown = matched(artist: "nirvana")
    assert_equal 3, [ us.artist_id, uk.artist_id, unknown.artist_id ].uniq.size
    assert_equal "name", unknown.artist_match
    assert_nil unknown.artist.mbid, "linked to a name-only artist, not to either identified Nirvana"
    review = unknown.catalogue_reviews.sole
    assert_equal [ "artist", "possible_match", "open" ], [ review.level, review.kind, review.state ]
    assert_equal [ us.artist_id, uk.artist_id ].sort, review.candidate_ids
  end

  test "variants without IDs share one name-only artist per normalised name" do
    a = matched(artist: "Sigur Rós")
    b = matched(artist: "  SIGUR   rós ")
    c = matched(artist: "Sigur Ros")
    assert_equal a.artist_id, b.artist_id
    assert_not_equal a.artist_id, c.artist_id, "accents are kept, so a differently spelled name is not assumed equal"
    assert_equal "Sigur Rós", a.artist.name
  end

  test "a curated alias links a name to exactly one artist" do
    beatles = matched(artist: "The Beatles", artist_mbid: BEATLES).artist
    Catalogue::Decisions.add_alias!(beatles, "Beatles")
    aliased = matched(artist: "BEATLES")
    assert_equal [ "alias", beatles.id ], [ aliased.artist_match, aliased.artist_id ]
  end

  test "an alias claimed by two artists is ambiguous and links to neither" do
    us = matched(artist: "Nirvana", artist_mbid: NIRVANA_US).artist
    uk = matched(artist: "Nirvana", artist_mbid: NIRVANA_UK).artist
    Catalogue::Decisions.add_alias!(us, "Nirvana (band)")
    Catalogue::Decisions.add_alias!(uk, "Nirvana (band)")
    result = matched(artist: "nirvana (band)", album: "Nevermind")
    assert_equal [ "ambiguous", "unmatched", "unmatched" ], levels(result)
    assert_nil result.artist_id
    assert_equal [ us.id, uk.id ].sort, result.catalogue_reviews.sole.candidate_ids
  end

  test "several name-only artists with one name make a new variant ambiguous" do
    first = matched(artist: "Nirvana").artist
    second = Artist.create!(name: "Nirvana") # a person split the name-only artist in two
    result = matched(artist: "Nirvana", track: "Other")
    assert_equal "ambiguous", result.artist_match
    assert_equal [ first.id, second.id ].sort, result.catalogue_reviews.sole.candidate_ids
  end

  test "recordings stay distinct: by MBID, by version in the title, and never joined by title alone" do
    one = matched(track: "Song", track_mbid: REC_1)
    two = matched(track: "Song", track_mbid: REC_2)
    live = matched(track: "Song (Live)")
    remaster = matched(track: "Song - 2011 Remaster")
    bare = matched(track: "Song")
    ids = [ one, two, live, remaster, bare ].map(&:track_id)
    assert_equal 5, ids.uniq.size
    assert_equal [ "mbid", "mbid", "name", "name", "name" ], [ one, two, live, remaster, bare ].map(&:track_match)
    assert_equal one.artist_id, bare.artist_id, "the same name-only artist"
    review = bare.catalogue_reviews.find_by!(level: "track")
    assert_equal [ "possible_match", [ one.track_id, two.track_id ].sort ], [ review.kind, review.candidate_ids ]
  end

  test "albums: none when missing, releases kept apart by MBID, name-only albums scoped to the artist" do
    none = matched(album: "")
    assert_equal [ "none", nil ], [ none.album_match, none.album_id ]

    r1 = matched(album: "Album", album_mbid: REL_1)
    r2 = matched(album: "Album", album_mbid: REL_2, track: "Other")
    assert_not_equal r1.album_id, r2.album_id, "two releases with one title"

    a = matched(artist: "First", album: "Greatest Hits")
    b = matched(artist: "Second", album: "Greatest Hits")
    c = matched(artist: "First", album: "greatest hits", track: "Other")
    assert_not_equal a.album_id, b.album_id
    assert_equal a.album_id, c.album_id
  end

  test "without a resolvable artist, albums and tracks stay unmatched" do
    result = matched(artist: "   ", album: "Album")
    assert_equal [ "unmatched", "unmatched", "unmatched" ], levels(result)
    assert_equal 0, Artist.count + Album.count + Track.count
  end

  test "an album or track MBID already known links even when the artist is uncertain" do
    known = matched(track: "Song", track_mbid: REC_1).track
    Catalogue::Decisions.add_alias!(Artist.create!(name: "A"), "Same")
    Catalogue::Decisions.add_alias!(Artist.create!(name: "B"), "Same")
    result = matched(artist: "Same", track: "Song", track_mbid: REC_1)
    assert_equal [ "ambiguous", "mbid" ], [ result.artist_match, result.track_match ]
    assert_equal known.id, result.track_id
  end

  test "matching again changes nothing and creates nothing" do
    [ { artist: "Nirvana", artist_mbid: NIRVANA_US }, { artist: "nirvana" }, { artist: "A", track: "Song", album: "Album" },
      { artist: "A", track: "Song", track_mbid: REC_1 } ].each { |fields| v(**fields) }
    links = -> { [ Artist.count, Album.count, Track.count, NameVariant.order(:id).pluck(:artist_id, :album_id, :track_id, :artist_match, :track_match, :matched_at) ] }
    reviews = -> { CatalogueReview.order(:id).pluck(:name_variant_id, :level, :kind, :candidate_ids, :state) }
    rematch = lambda do
      NameVariant.update_all(match_version: nil)
      @matcher.match_pending!
    end

    assert_equal 4, @matcher.match_pending!
    first_links = links.()
    assert_equal 0, @matcher.match_pending!, "everything is matched under the current rules"
    rematch.()
    assert_equal first_links, links.(), "links are final after one pass"
    # An entity created late in the first pass can raise a review for a variant matched earlier
    # (the bare "Song" before the identified one existed); from then on nothing changes.
    second_reviews = reviews.()
    3.times { rematch.() }
    assert_equal [ first_links, second_reviews ], [ links.(), reviews.() ]
  end

  test "matching never writes to scrobbles or changes a variant's strings" do
    user = history_user
    original = v(artist: " Exact  Artist ", track: "Track", album: "Album")
    scrobble(user, at: Time.utc(2014, 3, 1), variant: original)
    strings = original.attributes.slice(*NameVariant::IDENTITY_FIELDS.map(&:to_s), "variant_hash")
    writes = []
    callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { @matcher.match_pending! }
    assert_empty writes.grep(/scrobbles/), writes.join("\n")
    assert_equal strings, original.reload.attributes.slice(*strings.keys)
  end

  test "a manual decision sticks through re-matching and resolves the review" do
    us = matched(artist: "Nirvana", artist_mbid: NIRVANA_US).artist
    matched(artist: "Nirvana", artist_mbid: NIRVANA_UK)
    unknown = matched(artist: "nirvana", track: "Smells")
    Catalogue::Decisions.assign!(unknown, :artist, us, by: @reviewer)
    NameVariant.update_all(match_version: nil)
    @matcher.match_pending!
    unknown.reload
    assert_equal [ "manual", us.id ], [ unknown.artist_match, unknown.artist_id ]
    assert_equal us.id, unknown.track.artist_id, "the track was re-matched under the chosen artist"
    review = unknown.catalogue_reviews.find_by!(level: "artist")
    assert_equal [ "resolved", us.id, @reviewer.id ], [ review.state, review.chosen_id, review.decided_by_id ]
  end

  test "a dismissed review isn't reopened for the same candidates" do
    matched(artist: "Nirvana", artist_mbid: NIRVANA_US)
    unknown = matched(artist: "nirvana")
    Catalogue::Decisions.dismiss!(unknown.catalogue_reviews.sole, by: @reviewer)
    NameVariant.update_all(match_version: nil)
    @matcher.match_pending!
    assert_equal [ "dismissed" ], unknown.catalogue_reviews.pluck(:state)

    matched(artist: "Nirvana", artist_mbid: NIRVANA_UK) # a new candidate is a new question
    @matcher.match!(unknown)
    assert_equal %w[dismissed open], unknown.catalogue_reviews.order(:id).pluck(:state)
  end

  test "merging a name-only artist into an identified one re-attributes it without duplicating its tracks" do
    us = matched(artist: "Nirvana", artist_mbid: NIRVANA_US).artist
    unknown = matched(artist: "nirvana", track: "Lithium")
    name_only = unknown.artist
    track = unknown.track
    Catalogue::Decisions.merge!(name_only, us, by: @reviewer)
    unknown.reload
    assert_equal [ us.id, "manual" ], [ unknown.artist_id, unknown.artist_match ]
    assert_equal track.id, unknown.track_id, "the track found through the merged artist, not created again"
    assert_equal us, name_only.reload.merged_into, "nothing is deleted; the merge is recorded"
    assert_equal "resolved", unknown.catalogue_reviews.find_by!(level: "artist").state

    later = matched(artist: "NIRVANA", track: "Lithium")
    assert_equal [ us.id, track.id ], [ later.artist_id, later.track_id ], "new variants follow the merge"
    assert_raises(ArgumentError) { Catalogue::Decisions.merge!(us, name_only, by: @reviewer) }
  end

  test "better rules later re-link variants without re-importing" do
    first = matched(artist: "Beatles")
    beatles = matched(artist: "The Beatles", artist_mbid: BEATLES).artist
    Catalogue::Decisions.add_alias!(beatles, "Beatles")
    @matcher.match_pending!
    assert_equal [ "alias", beatles.id ], [ first.reload.artist_match, first.artist_id ]
    assert Artist.exists?(normalized_name: "beatles", mbid: nil), "the old name-only artist is kept, not deleted"
  end

  test "accounts are isolated: matching one user's history touches only their variants" do
    alice = history_user("alice")
    bob = history_user("bob")
    shared = v(artist: "Shared")
    alices = v(artist: "Alice only")
    bobs = v(artist: "Bob only")
    scrobble(alice, at: Time.utc(2014, 3, 1), variant: shared)
    scrobble(alice, at: Time.utc(2014, 3, 2), variant: alices)
    scrobble(bob, at: Time.utc(2014, 3, 1), variant: shared)
    scrobble(bob, at: Time.utc(2014, 3, 2), variant: bobs)
    bob_rows = Scrobble.where(user: bob).order(:id).pluck(:id, :name_variant_id, :played_at, :seq)

    assert_equal 2, @matcher.match_user!(alice)
    assert_nil bobs.reload.match_version
    assert shared.reload.artist_id, "catalogue data is shared"
    assert_equal bob_rows, Scrobble.where(user: bob).order(:id).pluck(:id, :name_variant_id, :played_at, :seq)
  end

  test "the database rejects a link state that contradicts the link" do
    variant = matched(artist: "Artist")
    album = Album.create!(artist: variant.artist, title: "X")
    assert_db_rejects { variant.update_columns(artist_match: "mbid", artist_id: nil) }
    assert_db_rejects { variant.reload.update_columns(album_match: "none", album_id: album.id) }
    assert_db_rejects { variant.update_columns(track_match: "guess") }
  end

  test "with history storage off, matching and decisions are refused and write nothing" do
    variant = v
    Rails.configuration.x.history_import_enabled = nil
    assert_raises(HistoryImport::DisabledError) { @matcher.match!(variant) }
    assert_raises(HistoryImport::DisabledError) { @matcher.match_pending! }
    assert_equal 0, Artist.count + Track.count
    assert_nil variant.reload.match_version
  end
end

# Real concurrency: separate connections, committed data, own clean-up.
class Catalogue::MatcherConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @flag = Rails.configuration.x.history_import_enabled
    Rails.configuration.x.history_import_enabled = "true"
    tag = SecureRandom.hex(4)
    @variants = Array.new(4) do |i|
      NameVariant.for!(artist_name: "Concurrent #{tag}#{' ' * (i % 2)}", track_name: "Song #{tag}", album_name: "",
                       track_mbid: i < 2 ? nil : "55555555-5555-4555-8555-#{tag}0000")
    end
  end

  teardown do
    ids = NameVariant.where(id: @variants.map(&:id))
    artist_ids = ids.pluck(:artist_id)
    ids.delete_all
    Track.where(artist_id: artist_ids).delete_all
    Artist.where(id: artist_ids).delete_all
    Rails.configuration.x.history_import_enabled = @flag
  end

  test "simultaneous matching of variants with one name creates one entity per identity" do
    start = Queue.new
    threads = @variants.map do |variant|
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection { Catalogue::Matcher.new.match!(variant) }
      end
    end
    @variants.size.times { start << :go }
    threads.each(&:join)
    rows = NameVariant.where(id: @variants.map(&:id)).pluck(:artist_id, :track_id)
    assert_equal 1, rows.map(&:first).uniq.size, "one name-only artist"
    assert_equal 2, rows.map(&:last).uniq.size, "one name-only track and one identified recording"
  end
end
