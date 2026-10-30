require "test_helper"

class Lastfm::RequestPacerTest < ActiveSupport::TestCase
  setup do
    @waits = []
    @key = "test-#{SecureRandom.hex(4)}"
  end

  def pacer(interval: 0.5, **options)
    Lastfm::RequestPacer.new(key: @key, interval: interval, sleeper: ->(s) { @waits << s }, **options)
  end

  test "the first request goes at once; the next waits about one interval" do
    p = pacer(interval: 0.5)
    assert_equal 0.0, p.reserve!
    assert_in_delta 0.5, p.reserve!, 0.1
    assert_equal 1, @waits.size
  end

  test "pacers in different processes share one schedule through the database" do
    first = pacer(interval: 0.5)
    second = pacer(interval: 0.5) # stands in for another process: same key, separate object
    first.reserve!
    assert_in_delta 0.5, second.reserve!, 0.1
    assert_in_delta 1.0, first.reserve!, 0.15
  end

  test "pacing still works with the query cache on, as it is in every request and job" do
    p = pacer(interval: 0.5)
    ActiveRecord::Base.connection.cache do
      p.reserve!
      assert_in_delta 0.5, p.reserve!, 0.1, "a cached reservation would return 0 and stop pacing"
      assert_in_delta 1.0, p.reserve!, 0.15
    end
  end

  test "a cool-down delays every pacer" do
    p = pacer(interval: 0.1)
    p.reserve!
    p.cool_down!(5)
    assert_in_delta 5.0, p.reserve!, 0.2
  end

  test "a wait longer than the maximum raises instead of blocking a worker" do
    p = pacer(interval: 0.1, max_wait: 2.0)
    p.cool_down!(30)
    error = assert_raises(Lastfm::Error::RateLimited) { p.reserve! }
    assert_operator error.retry_after, :>, 25
    assert_empty @waits
  end

  test "pacing writes only its own slot row, never history" do
    writes = []
    callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE)/i) }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { pacer.reserve! }
    assert writes.all? { |sql| sql.include?("api_request_slots") }, writes.inspect
  end
end

# Real concurrency: separate threads hold separate database connections, like separate processes.
# Needs committed data, so this class doesn't use transactional tests and cleans up its own row.
class Lastfm::RequestPacerConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup { @key = "concurrency-#{SecureRandom.hex(4)}" }
  teardown { ActiveRecord::Base.connection.exec_delete("DELETE FROM api_request_slots WHERE key = $1", "cleanup", [ @key ]) }

  test "concurrent callers each get a distinct slot, spaced by the interval" do
    interval = 0.2
    waits = Queue.new
    threads = Array.new(5) do
      Thread.new do
        pacer = Lastfm::RequestPacer.new(key: @key, interval: interval, sleeper: ->(_s) { })
        waits << pacer.reserve!
      end
    end
    threads.each(&:join)
    sorted = Array.new(5) { waits.pop }.sort
    gaps = sorted.each_cons(2).map { |a, b| b - a }
    assert gaps.all? { |gap| gap.between?(interval - 0.05, interval + 0.05) }, "gaps: #{gaps.inspect}"
  end
end
