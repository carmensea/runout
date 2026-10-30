require "test_helper"

class HistoryImport::WindowPlannerTest < ActiveSupport::TestCase
  include HistoryHelpers

  setup { @user = history_user }

  def plan(cutoff: Time.utc(2005, 1, 15)) = HistoryImport::WindowPlanner.plan!(user: @user, from: Time.utc(2004, 8, 7), cutoff: cutoff)

  test "plans one pending window per month up to the cutoff" do
    created = plan
    assert_equal 6, created.size
    assert_equal [ Time.utc(2004, 8, 1), Time.utc(2005, 1, 15) ], [ created.first.window_from, created.last.window_to ]
    assert created.all? { |w| w.state == "pending" }
  end

  test "re-planning is idempotent" do
    plan
    assert_empty plan
    assert_equal 6, @user.import_windows.count
  end

  test "never plans over a month that was split" do
    august = plan.first
    august.update!(state: "split")
    mid = Time.utc(2004, 8, 16)
    ImportWindow.create!(user: @user, parent_window: august, window_from: august.window_from, window_to: mid)
    ImportWindow.create!(user: @user, parent_window: august, window_from: mid, window_to: august.window_to)
    assert_empty plan
  end
end
