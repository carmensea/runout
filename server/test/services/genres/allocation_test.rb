require "test_helper"

# Period genre figures: allocated shares add up to exactly 1 with Unclassified; reach overlaps and is
# kept apart. Offline; synthetic data only.
class Genres::AllocationTest < ActiveSupport::TestCase
  R = Genres::Classifier::Result

  def result(broad, present: broad.keys) = R.new(broad: broad, sub: broad, present: present.to_set, signals_used: [])

  test "every play counts once: shares add up to 1, Unclassified included" do
    totals = Genres::Allocation.call([
      [ 10, result({ "rock" => 0.6, "pop" => 0.4 }) ],
      [ 5, result({ "pop" => 1.0 }) ],
      [ 5, result({ "unclassified" => 1.0 }, present: []) ]
    ])
    assert_equal 20, totals.plays
    assert_equal({ "rock" => 6.0, "pop" => 9.0, "unclassified" => 5.0 }, totals.broad)
    assert_in_delta 1.0, totals.broad_shares.values.sum, 1e-12
    assert_in_delta 0.25, totals.broad_shares["unclassified"]
  end

  test "reach overlaps: an artist in two genres counts fully towards both, and the reaches add up to more than 1" do
    totals = Genres::Allocation.call([ [ 10, result({ "rock" => 0.5, "pop" => 0.5 }) ], [ 10, result({ "pop" => 1.0 }) ] ])
    assert_equal({ "rock" => 10, "pop" => 20 }, totals.reach)
    assert_in_delta 1.5, totals.reach_shares.values.sum, 1e-12, "which is why reach is never summed or stacked"
    assert_in_delta 0.75, totals.broad_shares["pop"]
  end

  test "whole percentages add up to exactly 100 (largest remainder)" do
    assert_equal({ "a" => 33, "b" => 33, "c" => 34 }.values.sum, Genres::Allocation.whole_percentages({ "a" => 1 / 3.0, "b" => 1 / 3.0, "c" => 1 / 3.0 }).values.sum)
    assert_equal({ "a" => 67, "b" => 33 }, Genres::Allocation.whole_percentages({ "a" => 2 / 3.0, "b" => 1 / 3.0 }))
    rng = Random.new(7)
    200.times do
      raw = Array.new(rng.rand(1..9)) { rng.rand }
      shares = raw.each_with_index.to_h { |v, i| [ "g#{i}", v / raw.sum ] }
      assert_equal 100, Genres::Allocation.whole_percentages(shares).values.sum
    end
  end
end
