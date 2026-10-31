require "test_helper"

# The taxonomy seed: valid, idempotent, and never overwriting the owner's edits.
class Genres::SeedTest < ActiveSupport::TestCase
  test "the version-controlled taxonomy is valid: fourteen broad genres, every subgenre under one of them" do
    seed = Genres::Seed.new
    seed.validate!
    seed.apply!
    assert_equal 14, Genre.broad.count
    assert Genre.where(level: "sub").all? { |g| g.parent&.level == "broad" }
    assert_equal({ "min_tag_weight" => 10.0, "min_mapped_weight" => 10.0 }, TaxonomySetting.values)
    indie_rock = TagGenreMapping.where(tag: "indie rock").joins(:genre).pluck("genres.slug", :weight).to_h
    assert_equal({ "indie-rock" => 0.5, "rock" => 0.5 }, indie_rock.transform_values(&:to_f))
    TagGenreMapping.group(:tag).sum(:weight).each { |tag, total| assert_in_delta 1.0, total.to_f, 0.0011, tag }
  end

  test "applying again changes nothing; the owner's rows survive and seed rows dropped from the file go" do
    seed = Genres::Seed.new
    seed.apply!
    before = TagGenreMapping.order(:id).pluck(:id, :tag, :genre_id, :weight)
    seed.apply!
    assert_equal before, TagGenreMapping.order(:id).pluck(:id, :tag, :genre_id, :weight)

    rock = Genre.find_by!(slug: "rock")
    rock.update!(name: "Rock music", origin: "manual")
    mine = TagGenreMapping.find_by!(tag: "indie rock", genre: rock)
    mine.update!(weight: 0.3, origin: "manual")
    TagGenreMapping.create!(tag: "my own tag", genre: rock, weight: 1, origin: "manual")
    TagGenreMapping.create!(tag: "dropped from the file", genre: rock, weight: 1, origin: "seed")
    TaxonomySetting.find("min_tag_weight").update!(value: 25, origin: "manual")

    seed.apply!
    assert_equal "Rock music", rock.reload.name
    assert_equal [ 0.3, "manual" ], [ mine.reload.weight.to_f, mine.origin ]
    assert TagGenreMapping.exists?(tag: "my own tag")
    refute TagGenreMapping.exists?(tag: "dropped from the file")
    assert_equal 25.0, TaxonomySetting.values["min_tag_weight"]
  end

  test "a broken seed is refused before anything is written" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "taxonomy.yml")
      File.write(path, { broad: [ { slug: "rock", name: "Rock", tags: [ "rock" ] } ],
                         subgenres: [ { slug: "x", name: "X", parent: "rock", tags: [ "rock" ] } ] }.deep_stringify_keys.to_yaml)
      assert_raises(Genres::Seed::Invalid) { Genres::Seed.new(path).apply! }
      assert_equal 0, Genre.count
    end
  end
end
