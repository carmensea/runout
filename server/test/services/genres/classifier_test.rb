require "test_helper"

# Genre classification arithmetic (docs/backend-plan.md §6, docs/milestone-4-plan.md §3). Offline;
# synthetic signals only.
class Genres::ClassifierTest < ActiveSupport::TestCase
  GENRES = {
    "rock" => [ "broad", nil ], "indie-alternative" => [ "broad", nil ], "pop" => [ "broad", nil ], "electronic" => [ "broad", nil ],
    "indie-rock" => [ "sub", "indie-alternative" ], "post-punk" => [ "sub", "indie-alternative" ], "classic-rock" => [ "sub", "rock" ],
    "synth-pop" => [ "sub", "pop" ]
  }.freeze
  MAPPINGS = {
    "rock" => [ [ "rock", 1.0 ] ],
    "indie rock" => [ [ "indie-rock", 0.5 ], [ "rock", 0.5 ] ],
    "post-punk" => [ [ "post-punk", 1.0 ] ],
    "classic rock" => [ [ "classic-rock", 1.0 ] ],
    "synth-pop" => [ [ "synth-pop", 0.5 ], [ "electronic", 0.5 ] ]
  }.freeze

  def classify(signals, settings: TaxonomySetting::DEFAULTS)
    Genres::Classifier.new(mappings: MAPPINGS, genres: GENRES, settings: settings).call(signals)
  end

  def s(name, votes) = { name: name, votes: votes }

  test "votes are scaled to the strongest, and shares add up to exactly 1" do
    r = classify([ s("post-punk", 4), s("indie rock", 2), s("rock", 2) ])
    # post-punk 100 -> indie/post-punk 100; indie rock 50 -> indie/indie-rock 25 + rock 25; rock 50 -> rock 50.
    assert_in_delta 125.0 / 200, r.broad["indie-alternative"]
    assert_in_delta 75.0 / 200, r.broad["rock"]
    assert_in_delta 1.0, r.broad.values.sum, 1e-12
    refute r.unclassified?
  end

  test "subgenres split their broad genre; direct broad weight shows as Other" do
    r = classify([ s("post-punk", 4), s("indie rock", 2), s("rock", 2) ])
    assert_in_delta r.broad["indie-alternative"] * 100 / 125, r.sub["post-punk"]
    assert_in_delta r.broad["indie-alternative"] * 25 / 125, r.sub["indie-rock"]
    assert_in_delta r.broad["rock"], r.sub["other:rock"], 1e-12, "all of Rock came from the rock tag and indie rock's split"
    assert_in_delta 1.0, r.sub.values.sum, 1e-12
    GENRES.select { |_, (level, _)| level == "broad" }.each_key do |broad|
      subs = r.sub.select { |slug, _| slug == "other:#{broad}" || GENRES.dig(slug, 1) == broad }
      assert_in_delta r.broad.fetch(broad, 0), subs.values.sum, 1e-12, broad
    end
  end

  test "unmapped names count for nothing; with too little mapped weight the item is Unclassified, not guessed" do
    assert classify([]).unclassified?
    assert classify([ s("seen live", 10), s("female vocalists", 4) ]).unclassified?
    r = classify([ s("seen live", 100), s("post-punk", 5) ])
    assert r.unclassified?, "post-punk weighs 5 against the strongest tag's 100: below min_tag_weight"
    assert_equal({ "unclassified" => 1.0 }, r.broad)
    assert_empty r.present

    r = classify([ s("seen live", 100), s("post-punk", 12) ])
    refute r.unclassified?
    assert_equal({ "indie-alternative" => 1.0 }, r.broad)
  end

  test "names are compared in lower case with single spaces; zero votes are ignored" do
    r = classify([ s("  Indie   Rock ", 3), s("rock", 0) ])
    assert_in_delta 0.5, r.broad["rock"]
    assert_equal [ "  Indie   Rock " ], r.signals_used
  end

  test "settings are honoured" do
    strict = { "min_tag_weight" => 60, "min_mapped_weight" => 10 }
    assert_equal [ "indie-alternative" ], classify([ s("post-punk", 10), s("rock", 5) ], settings: strict).broad.keys
  end

  test "reach lists every genre with any weight, broad and sub" do
    r = classify([ s("indie rock", 1), s("synth-pop", 1) ])
    assert_equal %w[electronic indie-alternative indie-rock pop rock synth-pop].to_set, r.present
  end

  test "property: any signals give broad shares adding to 1 and subgenres adding to their broad genre" do
    rng = Random.new(2026)
    names = MAPPINGS.keys + [ "unmapped", "seen live" ]
    500.times do
      signals = Array.new(rng.rand(0..6)) { s(names.sample(random: rng), rng.rand(0..20)) }
      r = classify(signals)
      assert_in_delta 1.0, r.broad.values.sum, 1e-9
      assert_in_delta 1.0, r.sub.values.sum, 1e-9
      assert(r.broad.values.all? { |v| v.positive? && v <= 1 + 1e-12 })
    end
  end
end
