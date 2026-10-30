require "test_helper"

# Real concurrency: threads hold separate database connections, like separate worker processes.
# Committed data is needed, so no transactional wrapper; the test cleans up its own rows.
class HistoryImport::WindowConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @flag = Rails.configuration.x.history_import_enabled
    Rails.configuration.x.history_import_enabled = "true"
    @user = User.create!(display_name: "concurrency-#{SecureRandom.hex(4)}")
    @window = ImportWindow.create!(user: @user, window_from: Time.utc(2014, 3, 1), window_to: Time.utc(2014, 4, 1))
  end

  teardown do
    @user.destroy! # cascades to windows
    Rails.configuration.x.history_import_enabled = @flag
  end

  test "exactly one of several simultaneous workers claims a window" do
    start = Queue.new
    results = Queue.new
    threads = Array.new(6) do
      Thread.new do
        start.pop
        ActiveRecord::Base.connection_pool.with_connection do
          token = SecureRandom.uuid
          results << [ token, ImportWindow.find(@window.id).claim_for_validation!(token) ]
        end
      end
    end
    6.times { start << :go }
    threads.each(&:join)
    outcomes = Array.new(6) { results.pop }
    winners = outcomes.select(&:last)
    assert_equal 1, winners.size
    assert_equal winners.sole.first, @window.reload.claim_token
    assert_equal 1, @window.attempts
  end
end
