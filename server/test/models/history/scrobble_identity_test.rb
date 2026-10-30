require "test_helper"

class ScrobbleIdentityTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup do
    @user = history_user
    @at = Time.utc(2014, 3, 15, 20, 15, 0)
  end

  test "each scrobble has its own internal id" do
    a = scrobble(@user, at: @at)
    b = scrobble(@user, at: @at + 1)
    assert_not_equal a.id, b.id
  end

  test "identical plays in the same second are kept as separate rows" do
    v = variant(track: "Same Track")
    first = scrobble(@user, at: @at, seq: 0, variant: v)
    second = scrobble(@user, at: @at, seq: 1, variant: v)
    assert_equal 2, @user.scrobbles.where(played_at: @at, name_variant: v).count
    assert_not_equal first.id, second.id
  end

  test "identity is (user, played_at, seq), not the track" do
    scrobble(@user, at: @at, seq: 0, variant: variant(track: "A"))
    assert_db_rejects(ActiveRecord::RecordNotUnique) { scrobble(@user, at: @at, seq: 0, variant: variant(track: "B")) }
    assert scrobble(history_user("other"), at: @at, seq: 0), "another user may have a play in the same second"
  end

  test "seq cannot be negative" do
    assert_db_rejects { Scrobble.insert_all!([ { user_id: @user.id, played_at: @at, seq: -1, name_variant_id: variant.id, created_at: Time.current } ]) }
  end

  test "date ranges are half-open, like Last.fm's" do
    scrobble(@user, at: @at)
    scrobble(@user, at: @at + 60)
    assert_equal 1, @user.scrobbles.played_between(@at, @at + 60).count
    assert_equal 2, @user.scrobbles.played_between(@at, @at + 61).count
  end

  test "a name variant hashes the exact strings: case, spacing and missing MBIDs all count" do
    base = { artist_name: "Artist", track_name: "Track", album_name: "Album" }
    hashes = [
      NameVariant.hash_for(base),
      NameVariant.hash_for(base.merge(track_name: "track")),
      NameVariant.hash_for(base.merge(track_name: "Track ")),
      NameVariant.hash_for(base.merge(track_mbid: "")),
      NameVariant.hash_for(base.merge(album_name: ""))
    ]
    assert_equal hashes.size, hashes.uniq.size
    assert_equal 32, hashes.first.bytesize
  end

  test "the same strings always resolve to the same variant" do
    a = variant(track: "Hoppípolla", artist: "Sigur Rós")
    b = variant(track: "Hoppípolla", artist: "Sigur Rós")
    assert_equal a.id, b.id
    assert_equal 1, NameVariant.count
  end

  test "a variant's strings can never be edited" do
    v = variant(track: "Original")
    v.track_name = "Edited"
    assert_not v.save
    assert_equal "Original", v.reload.track_name
  end

  test "a variant referenced by scrobbles cannot be deleted" do
    v = variant
    scrobble(@user, at: @at, variant: v)
    assert_db_rejects(ActiveRecord::InvalidForeignKey) { NameVariant.where(id: v.id).delete_all }
  end
end
