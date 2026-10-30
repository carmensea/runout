require "test_helper"

class CatalogTest < ActiveSupport::TestCase
  include HistoryHelpers

  test "names are normalised for matching: NFKC, case-folded, trimmed, whitespace collapsed" do
    assert_equal "sigur rós", CatalogName.normalize("  SIGUR   Rós ")
    assert_equal "ﬁ".unicode_normalize(:nfkc), CatalogName.normalize("ﬁ")
    assert_equal "strasse", CatalogName.normalize("STRASSE")
  end

  test "MusicBrainz IDs are unique when present and optional otherwise" do
    Artist.create!(name: "Nirvana", mbid: "5b11f4ce-a62d-471e-81fc-a69a8278c7da")
    assert_db_rejects(ActiveRecord::RecordNotUnique) do
      Artist.insert_all!([ { name: "Nirvana", normalized_name: "nirvana", mbid: "5b11f4ce-a62d-471e-81fc-a69a8278c7da",
                             created_at: Time.current, updated_at: Time.current } ])
    end
    assert Artist.create!(name: "No MBID")
    assert Artist.create!(name: "Also no MBID")
  end

  test "the same normalised name never forces two artists together" do
    us = Artist.create!(name: "Nirvana", mbid: "5b11f4ce-a62d-471e-81fc-a69a8278c7da")
    uk = Artist.create!(name: "Nirvana", mbid: "9282c8b4-ca0b-4c6b-b7e3-4f7762dfc4d6")
    unknown = Artist.create!(name: "nirvana")
    assert_equal 3, Artist.where(normalized_name: "nirvana").count
    assert_equal [ us, uk, unknown ].map(&:normalized_name).uniq, [ "nirvana" ]
  end

  test "recordings with the same title stay separate" do
    artist = Artist.create!(name: "Artist")
    Track.create!(artist: artist, title: "Song", mbid: "11111111-1111-1111-1111-111111111111")
    Track.create!(artist: artist, title: "Song", mbid: "22222222-2222-2222-2222-222222222222")
    assert_equal 2, artist.tracks.where(normalized_title: "song").count
  end

  test "better matching later re-attributes history without touching any scrobble" do
    user = history_user
    v = variant(track: "Song", artist: "Artist")
    s = scrobble(user, at: Time.utc(2014, 3, 15), variant: v)
    first_guess = Artist.create!(name: "Artist")
    v.update!(artist: first_guess, match_method: "normalized_name", matched_at: Time.current)

    better = Artist.create!(name: "Artist", mbid: "33333333-3333-3333-3333-333333333333")
    first_guess.update!(merged_into: better)
    v.update!(artist: better, match_method: "manual", matched_at: Time.current)

    assert_equal better, s.reload.name_variant.artist
    assert_equal v.id, s.name_variant_id, "the scrobble row itself is unchanged"
  end

  test "match methods are constrained" do
    v = variant
    assert_db_rejects { v.update_columns(match_method: "guess") }
  end
end
