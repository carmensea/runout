# Time Machine benchmark: GET /api/calendar, /api/plays and /api/on-this-day on a synthetic history
# written straight into a disposable database (these endpoints only read, so the import pipeline isn't
# needed to fill it). Plays aren't matched to the catalogue, so every identity key comes from names:
# the costlier path. Synthetic data only.
#
#   export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
#   SCROBBLES=1000000 bin/rails runner test/benchmark/time_machine_benchmark.rb
abort "benchmark: RAILS_ENV must be test" unless Rails.env.test?
DATABASE = ActiveRecord::Base.connection.current_database
abort "benchmark: refusing to run against #{DATABASE}" unless %w[runout_smoke runout_bench].include?(DATABASE)
ActiveRecord::Base.connection_pool.disable_query_cache!

SCROBBLES = Integer(ENV.fetch("SCROBBLES", "209000"))
conn = ActiveRecord::Base.connection
tables = %w[catalogue_inferences mbid_disputes review_decisions reconciliation_disputes scrobble_removals scrobble_corrections
            catalogue_reviews artist_aliases scrobbles import_window_rows import_window_fetches import_windows import_runs
            name_variants tracks albums artists lastfm_connections sessions identities users]
conn.execute("TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE")

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
user_id = conn.select_value("INSERT INTO users (display_name, reporting_timezone, created_at, updated_at) " \
                            "VALUES ('Benchmark', 'America/Los_Angeles', now(), now()) RETURNING id")
variants = [ SCROBBLES / 10, 1000 ].max
artists = [ variants / 7, 100 ].max
# Name variants: artist i % artists, track and album strings; hashes stand in for real ones (unique).
conn.execute(<<~SQL)
  INSERT INTO name_variants (variant_hash, artist_name, track_name, album_name, created_at)
  SELECT sha256(convert_to('bench-' || g, 'UTF8')), 'Artist ' || (g % #{artists}), 'Track ' || g, 'Album ' || (g / 9), now()
    FROM generate_series(1, #{variants}) g
SQL
# Plays over 20 years, denser later, popular variants played more; every 50th second has two plays.
conn.execute(<<~SQL)
  INSERT INTO scrobbles (user_id, played_at, seq, name_variant_id, created_at)
  SELECT '#{user_id}', t, s, v, now() FROM (
    SELECT timestamp '2006-01-01' + (sqrt(g::float / #{SCROBBLES}) * interval '20 years') AS t,
           0 AS s, 1 + floor(power(random(), 2) * #{variants})::int AS v
      FROM generate_series(1, #{SCROBBLES}) g
  ) p
  ON CONFLICT DO NOTHING
SQL
conn.execute(<<~SQL)
  INSERT INTO scrobbles (user_id, played_at, seq, name_variant_id, created_at)
  SELECT user_id, played_at, 1, name_variant_id, now() FROM scrobbles WHERE id % 50 = 0
SQL
conn.execute(<<~SQL)
  INSERT INTO import_windows (user_id, window_from, window_to, state, validated_at, committed_at, committed_count, created_at, updated_at)
  VALUES ('#{user_id}', '2006-01-01', '2026-01-01', 'committed', now(), now(), 0, now(), now())
SQL
conn.execute("ANALYZE")
user = User.find(user_id)
plays = Scrobble.where(user: user).count
puts format("history: %d plays, %d name variants, written in %.1f s", plays, variants, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)

def measure(runs: 5)
  times = Array.new(runs) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
  end
  { median_ms: times.sort[runs / 2], max_ms: times.max }
end

tz = user.reporting_timezone
period = ->(raw) { Analytics::Period.parse(raw, time_zone: tz, today: Date.new(2026, 1, 1)) }
busiest = Scrobble.where(user: user).group("((played_at AT TIME ZONE 'UTC') AT TIME ZONE '#{tz}')::date").order("count_all DESC").limit(1).count.first
deep = Analytics::Plays.new(user: user, period: period.("year:2024"), limit: 500).call
4.times { deep = Analytics::Plays.new(user: user, period: period.("year:2024"), cursor: deep[:nextCursor], limit: 500).call }
cases = {
  "calendar: whole history" => -> { Analytics::Calendar.new(user: user).history },
  "calendar: a year of days" => -> { Analytics::Calendar.new(user: user).days(Date.new(2024, 1, 1), Date.new(2024, 12, 31)) },
  "calendar: a month of days" => -> { Analytics::Calendar.new(user: user).days(Date.new(2024, 3, 1), Date.new(2024, 3, 31)) },
  "plays: busiest day (#{busiest[0]}, #{busiest[1]} plays)" => -> { Analytics::Plays.new(user: user, period: period.("day:#{busiest[0]}")).call },
  "plays: a month, first page" => -> { Analytics::Plays.new(user: user, period: period.("month:2024-03")).call },
  "plays: a year, first page" => -> { Analytics::Plays.new(user: user, period: period.("year:2024")).call },
  "plays: a year, page after 2,500" => -> { Analytics::Plays.new(user: user, period: period.("year:2024"), cursor: deep[:nextCursor]).call },
  "on this day (20 years)" => -> { Analytics::OnThisDay.new(user: user, date: Date.new(2025, 10, 31)).call },
}
cases.each { |name, run| puts format("%-46s %s", name, measure(&run).inspect) }
