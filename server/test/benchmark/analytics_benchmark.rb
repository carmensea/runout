# Milestone 3 benchmark: Overview and Search response times on a synthetic history imported by
# test/benchmark/history_benchmark.rb (run it first with STOP_AFTER=matching). Same disposable
# database rules; reads only.
#
#   export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
#   bin/rails runner test/benchmark/analytics_benchmark.rb
abort "benchmark: RAILS_ENV must be test" unless Rails.env.test?
DATABASE = ActiveRecord::Base.connection.current_database
abort "benchmark: refusing to run against #{DATABASE}" unless %w[runout_smoke runout_bench].include?(DATABASE)
ActiveRecord::Base.connection_pool.disable_query_cache!

user = User.find_by!(display_name: "Benchmark")
user.update!(reporting_timezone: "Europe/London")
plays = Scrobble.where(user: user).count
rss = -> { `ps -o rss= -p #{Process.pid}`.to_i / 1024 }

def measure(runs: 3)
  queries = 0
  counter = ->(*, payload) { queries += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
  times = Array.new(runs) do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end
  { median_ms: times.sort[runs / 2], max_ms: times.max, queries: queries / runs }
end

today = Date.new(2026, 10, 1)
periods = %w[all l12 year:2014 year:2025 month:2014-03 week:2014-W11 day:2014-03-15 custom:2010-01-01..2014-12-31]
results = { plays: plays, rss_start_mb: rss.call, overview: {}, search: {} }
periods.each do |raw|
  period = Analytics::Period.parse(raw, time_zone: user.reporting_timezone, today: today)
  results[:overview][raw] = measure { Analytics::Overview.new(user: user, period: period).call }
  puts "overview #{raw.ljust(32)} #{results[:overview][raw]}"
end
compare = measure do
  [ "year:2014", "year:2013" ].each do |raw|
    Analytics::Overview.new(user: user, period: Analytics::Period.parse(raw, time_zone: user.reporting_timezone, today: today)).call
  end
end
results[:comparison_year_pair] = compare
puts "comparison year:2014 vs year:2013   #{compare}"
%w[artist 12 track\ 3-1 artst\ 4 zz album\ 5-2 Artïst].each do |q|
  results[:search][q] = measure(runs: 5) { Analytics::Search.new(user: user, query: q).call }
  puts "search #{q.inspect.ljust(16)} #{results[:search][q]}"
end
results[:rss_end_mb] = rss.call
puts "memory: #{results[:rss_start_mb]} MB at start, #{results[:rss_end_mb]} MB at end"
File.write(ENV.fetch("OUT", Rails.root.join("tmp/analytics-benchmark-#{plays}.json").to_s), JSON.pretty_generate(results))
