require "test_helper"

class HistoryImport::MonthlyWindowsTest < ActiveSupport::TestCase
  def ranges(from, cutoff) = HistoryImport::MonthlyWindows.ranges(from: from, cutoff: cutoff)

  test "starts at the first of the registration month and ends at the cutoff" do
    result = ranges(Time.utc(2004, 8, 7, 11, 3, 30), Time.utc(2004, 10, 15))
    assert_equal [ Time.utc(2004, 8, 1)...Time.utc(2004, 9, 1), Time.utc(2004, 9, 1)...Time.utc(2004, 10, 1),
                   Time.utc(2004, 10, 1)...Time.utc(2004, 10, 15) ], result
  end

  test "February is exact in leap and non-leap years, including century rules" do
    { 2023 => 28, 2024 => 29, 2000 => 29, 2100 => 28 }.each do |year, days|
      feb = ranges(Time.utc(year, 2, 1), Time.utc(year, 3, 2)).first
      assert_equal days * 86_400, feb.end - feb.begin, "#{year}"
    end
  end

  test "December rolls over to January of the next year" do
    assert_equal Time.utc(2015, 1, 1), ranges(Time.utc(2014, 12, 5), Time.utc(2015, 2, 1)).first.end
  end

  test "ranges are contiguous and half-open: no gaps and no overlaps" do
    result = ranges(Time.utc(2004, 8, 7), Time.utc(2026, 10, 29, 18))
    assert_equal 267, result.size
    result.each_cons(2) { |a, b| assert_equal a.end, b.begin }
    assert result.all?(&:exclude_end?)
    assert_equal Time.utc(2026, 10, 29, 18), result.last.end, "the current month is cut at the cutoff"
  end

  test "nothing to plan when the cutoff isn't after the start" do
    assert_empty ranges(Time.utc(2014, 3, 1), Time.utc(2014, 3, 1))
  end
end
