require "test_helper"

# Genre and artist-metadata figures in the Overview, and a genre's drill-down
# (docs/milestone-4-plan.md §3, §4, §7). Synthetic catalogue, metadata and plays only.
class Analytics::GenreFiguresTest < ActiveSupport::TestCase
  include HistoryHelpers

  CURE = "69ee3720-a7cb-4402-b48d-a02c366f2bcf".freeze
  SWIFT = "20244d07-534f-4eff-b4d4-930878889970".freeze
  SILENT = "11111111-1111-4111-8111-111111111111".freeze
  LATER = "22222222-2222-4222-8222-222222222222".freeze

  setup do
    Genres::Seed.new.apply!
    @user = history_user
    @user.update!(reporting_timezone: "UTC")
    @at = Time.utc(2014, 3, 1)
  end

  def artist(name, mbid: nil, plays: 1, year: 2014, track: "Song")
    v = variant(artist: name, track: "#{track} #{name}", album: "", **(mbid ? { artist_mbid: mbid } : {}))
    Catalogue::Matcher.new.match!(v)
    plays.times { @at += 60; scrobble(@user, at: @at.change(year: year), variant: v.reload) }
    v
  end

  def provider(mbid, name, type:, gender: nil, genres: [])
    MetadataArtist.create!(provider: "musicbrainz", provider_id: mbid, name: name, artist_type: type, gender: gender,
                           core_license: "CC0-1.0", source_url: "https://musicbrainz.org/ws/2/artist/#{mbid}", fetched_at: Time.current)
    genres.each do |g, votes|
      MetadataTag.create!(provider: "musicbrainz", entity_kind: "artist", provider_id: mbid, kind: "genre", name: g, votes: votes,
                          license: "CC-BY-NC-SA-3.0", fetched_at: Time.current)
    end
  end

  def overview(raw = "all") = Analytics::Overview.new(user: @user, period: Analytics::Period.parse(raw, time_zone: "UTC")).call

  def detail(slug, raw = "all") = Analytics::GenreDetail.new(user: @user, period: Analytics::Period.parse(raw, time_zone: "UTC"), slug: slug).call

  def library
    artist("The Cure", mbid: CURE, plays: 6)
    artist("Taylor Swift", mbid: SWIFT, plays: 4, year: 2015)
    artist("Silent Band", mbid: SILENT, plays: 2)       # looked up: no genres
    artist("Later Band", mbid: LATER, plays: 3)         # identified, not looked up yet
    artist("Nobody Knows", plays: 5)                    # name-only
    provider(CURE, "The Cure", type: "Group", genres: [ [ "post-punk", 2 ], [ "new wave", 2 ] ])
    provider(SWIFT, "Taylor Swift", type: "Person", gender: "Female", genres: [ [ "pop", 3 ], [ "country", 1 ] ])
    provider(SILENT, "Silent Band", type: "Group")
    Genres::Classifications.recompute!
  end

  test "before any enrichment, genres and metadata stay null: nothing is shown as known" do
    artist("The Cure", mbid: CURE)
    o = overview
    assert_nil o[:genres]
    assert_nil o[:metadata]
  end

  test "shares add up to exactly 1 with Unclassified, which is broken down by reason" do
    library
    g = overview[:genres]
    b = g[:broad]
    assert_in_delta 1.0, b[:categories].sum { |c| c[:share] } + b[:untaggedShare], 1e-12
    assert_in_delta 10.0 / 20, b[:untaggedShare]
    assert_equal({ "notIdentified" => 5 / 20.0, "notLookedUp" => 3 / 20.0, "noGenres" => 2 / 20.0 }, b[:unclassified])
    assert_equal [ "artist", "MusicBrainz", "CC BY-NC-SA 3.0" ], [ g[:level], g[:source][:provider], g[:source][:license] ]
    assert_in_delta 1.0, g[:sub][:categories].sum { |c| c[:share] } + g[:sub][:untaggedShare], 1e-12

    # The Cure: post-punk and new wave equally; post-punk gives 0.3 to Punk & hardcore, new wave 0.3 to Pop.
    indie = b[:categories].find { |c| c[:id] == "indie-alternative" }
    assert_in_delta 6 * 0.7 / 20, indie[:share]
    assert_equal [ [ "The Cure", 4 ] ], indie[:topArtists].map { |a| [ a[:name], a[:scrobbles] ] }
    assert_includes indie[:subgenres], "Post-punk"
    pop = b[:categories].find { |c| c[:id] == "pop" }
    assert_in_delta (6 * 0.15 + 4 * 0.75) / 20, pop[:share]
  end

  test "each year's shares add up to 1, by the period's own categories" do
    library
    years = overview[:genres][:broad][:byYear]
    assert_equal [ 2014, 2015 ], years.map { |y| y[:year] }
    years.each { |y| assert_in_delta 1.0, y[:shares].values.sum, 1e-12 }
    json = JSON.parse(overview[:genres].to_json)
    assert(json.dig("broad", "byYear").all? { |y| y["shares"].values.all?(Float) }, "shares are numbers in JSON, not strings")
    assert(json.dig("broad", "categories").all? { |c| c["share"].is_a?(Float) })
    assert_in_delta 0.75, years.last[:shares]["pop"], 1e-12, "2015 is all Taylor Swift"
  end

  test "more than six genres: the rest are one Other slot, and the shares still add up" do
    names = %w[post-punk house trap jazz baroque reggae flamenco opera]
    names.each_with_index do |g, i|
      mbid = format("%08d-0000-4000-8000-%012d", i, i)
      artist("Artist #{i}", mbid: mbid, plays: 10 - i)
      provider(mbid, "Artist #{i}", type: "Group", genres: [ [ g, 1 ] ])
    end
    Genres::Classifications.recompute!
    b = overview[:genres][:broad]
    assert_equal 7, b[:categories].size
    assert_equal "other", b[:categories].last[:id]
    assert_in_delta 1.0, b[:categories].sum { |c| c[:share] } + b[:untaggedShare], 1e-12
  end

  test "artist metadata: listed values only, missing kept as categories, by artists and by plays" do
    library
    m = overview[:metadata]
    assert_equal({ "female" => 1, "group" => 2, "not_looked_up" => 1, "not_identified" => 1 }, m[:byArtists].reject { |_, v| v.zero? },
                 "The Cure and Silent Band are groups, never a gender")
    assert_equal({ "female" => 4, "group" => 8, "not_looked_up" => 3, "not_identified" => 5 }, m[:byScrobbles].reject { |_, v| v.zero? })
    assert_equal 20, m[:byScrobbles].values.sum, "nothing missing drops out of the total"
    assert(JSON.parse(m.to_json)["byScrobbles"].values.all?(Integer), "counts are numbers in JSON, not strings")
    assert_equal 1, m[:unmatchedArtists]

    MetadataOverride.create!(entity_kind: "artist", provider_id: SILENT, field: "artist_type", value: "Orchestra")
    assert_equal 2, overview[:metadata][:byScrobbles]["orchestra_choir"], "the owner's correction wins"
  end

  test "a name-only twin merged into its identified artist counts with that artist's genres, once" do
    artist("The Cure", mbid: CURE, plays: 2)
    artist("the cure", plays: 3)
    Catalogue::ArtistInference.new.apply!
    provider(CURE, "The Cure", type: "Group", genres: [ [ "post-punk", 1 ] ])
    Genres::Classifications.recompute!
    b = overview[:genres][:broad]
    assert_in_delta 0.0, b[:untaggedShare]
    assert_equal [ "a#{Artist.find_by!(mbid: CURE).id}" ], b[:categories].flat_map { |c| c[:topArtists].map { |a| a[:id] } }.uniq, "one artist"
    assert_in_delta 0.7, b[:categories].find { |c| c[:id] == "indie-alternative" }[:share]
  end

  test "a genre's detail: allocated plays, share, reach kept apart, subgenres, artists, tracks and years" do
    library
    d = detail("pop")
    assert_equal [ "pop", "Pop", "broad", nil ], d[:genre].values_at(:slug, :name, :level, :parent)
    assert_equal 20, d[:plays]
    assert_in_delta 6 * 0.15 + 4 * 0.75, d[:allocated], 0.01
    assert_in_delta d[:allocated] / 20, d[:share]
    assert_equal 10, d[:reach][:plays], "every play by an artist with any pop counts in reach"
    assert_operator d[:reach][:share], :>=, d[:share]
    assert_in_delta d[:allocated], d[:subgenres].sum { |s| s[:allocated] }, 0.05, "subgenres split the genre's plays"
    assert_equal [ "Taylor Swift", "The Cure" ], d[:topArtists].map { |a| a[:name] }
    assert_in_delta 0.75, d[:topArtists].first[:genreShare]
    assert_equal [ "Song Taylor Swift", "Song The Cure" ], d[:topTracks].map { |t| t[:name] }
    assert_equal [ 2014, 2015 ], d[:byYear].map { |y| y[:year] }
    assert_in_delta 0.5, d[:unclassifiedShare]
    assert_equal "artist", d[:methodology][:level]

    sub = detail("post-punk")
    assert_equal({ slug: "indie-alternative", name: "Indie & alternative" }, sub[:genre][:parent])
    assert_empty sub[:subgenres]
    assert_raises(Analytics::GenreDetail::UnknownGenre) { detail("nonsense") }
  end
end
