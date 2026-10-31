require "test_helper"

# Milestone 3: search over the user's own history (Analytics::Search). Synthetic data only.
class Analytics::SearchTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup { @user = history_user }

  def search(q, user: @user) = Analytics::Search.new(user: user, query: q).call

  def play(track:, artist:, album: "Album", user: @user, times: 1, match: true, **mbids)
    v = variant(track: track, artist: artist, album: album, **mbids)
    Catalogue::Matcher.new.match!(v) if match
    times.times { scrobble(user, at: Time.utc(2014, 3, 1) + ((@minute = @minute.to_i + 1) * 60), variant: v) }
    v
  end

  test "partial, case-insensitive matches across artists, albums and tracks" do
    play(track: "Paranoid Android", artist: "Radiohead", album: "OK Computer")
    r = search("RADIO")
    assert_equal [ "Radiohead" ], r[:artists].map { |a| a[:name] }
    assert_equal [ { name: "Paranoid Android", artist: "Radiohead" } ], search("android")[:tracks].map { |t| t.slice(:name, :artist) }
    assert_equal [ "OK Computer" ], search("comp")[:albums].map { |a| a[:name] }
    assert_match(/\Aa\d+\z/, r[:artists].first[:id], "the same identity key as the Overview")
  end

  test "misspellings still find the artist" do
    play(track: "Karma Police", artist: "Radiohead")
    assert_equal [ "Radiohead" ], search("radiohed")[:artists].map { |a| a[:name] }
    assert_equal [ "Karma Police" ], search("karma polise")[:tracks].map { |t| t[:name] }
  end

  test "exact and prefix matches come first, then the more played" do
    play(track: "A", artist: "The Cure", times: 1)
    play(track: "B", artist: "Cure for Pain", times: 5)
    play(track: "C", artist: "Secure", times: 9)
    assert_equal [ "The Cure", "Cure for Pain", "Secure" ].sort, search("cure")[:artists].map { |a| a[:name] }.sort
    assert_equal "Cure for Pain", search("cure")[:artists].first[:name], "a name starting with the query first"
    assert_equal "The Cure", search("the cure")[:artists].first[:name], "an exact name first"
  end

  test "plays not matched to the catalogue yet can be found too" do
    play(track: "Hidden Song", artist: "Unmatched Artist", match: false)
    r = search("unmatched")
    assert_equal [ "Unmatched Artist" ], r[:artists].map { |a| a[:name] }
    assert_match(/\An\h{32}\z/, r[:artists].first[:id])
    assert_equal [ "Hidden Song" ], search("hidden")[:tracks].map { |t| t[:name] }
  end

  test "another user's listening is never found; removed plays don't count" do
    other = history_user("other")
    play(track: "Their Song", artist: "Their Band", user: other)
    assert_empty search("their")[:artists]
    assert_empty search("their")[:tracks]

    play(track: "Shared", artist: "Shared Band")
    removed = play(track: "Gone", artist: "Gone Band")
    Scrobble.where(name_variant: removed).update_all(removed_at: Time.current)
    assert_equal [ "Shared Band" ], search("band")[:artists].map { |a| a[:name] }
  end

  test "queries shorter than two characters return nothing" do
    play(track: "X", artist: "X")
    assert_equal({ artists: [], albums: [], tracks: [] }, search("x"))
  end
end
