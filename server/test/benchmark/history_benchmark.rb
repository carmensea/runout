# Stage 2.9 benchmark: the real import pipeline (orchestrator, validator, committer, reconciler,
# catalogue matcher, sync planner, recovery) on a synthetic history, in one process, against a
# disposable database. Last.fm is an in-process fake (no network), so the times measured are
# Runout's own processing; API waiting is estimated separately from the request counts.
#
#   export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
#   SCROBBLES=209000 bin/rails runner test/benchmark/history_benchmark.rb
#
# Options: SCROBBLES (default 209000), SEED, FAILURES=1 (transient 502s on 3% of requests and one
# crash mid-commit, then recovery), OUT (JSON results file), STOP_AFTER=matching (keep the history
# for test/benchmark/analytics_benchmark.rb). Synthetic data only; refuses any
# database but the disposable ones. Truncates history tables in that database first.
require "webmock"
require "objspace"

abort "benchmark: RAILS_ENV must be test" unless Rails.env.test?
DATABASE = ActiveRecord::Base.connection.current_database
abort "benchmark: refusing to run against #{DATABASE}" unless %w[runout_smoke runout_bench].include?(DATABASE)

Rails.configuration.x.history_import_enabled = "true" # this process, this disposable database only
ActiveJob::Base.queue_adapter = :test                 # steps are driven inline below
ActiveRecord::Base.connection_pool.disable_query_cache!

module Bench
  SCROBBLES = Integer(ENV.fetch("SCROBBLES", "209000"))
  SEED = Integer(ENV.fetch("SEED", "2026"))
  FAILURES = ENV["FAILURES"] == "1"
  USERNAME = "bench-listener".freeze
  START = Time.utc(2004, 3, 1)
  T0 = Time.utc(2026, 10, 1, 12) # the import's "now"; the history ends before it
  Play = Struct.new(:at, :artist, :artist_mbid, :track, :track_mbid, :album, :album_mbid)

  module_function

  def random = @random ||= Random.new(SEED)

  # Zipf-like rank: a few artists and tracks get most plays, as real libraries do.
  def zipf(n, s = 1.1)
    @zipf ||= {}
    cdf = @zipf[[ n, s ]] ||= begin
      weights = (1..n).map { |k| 1.0 / (k**s) }
      total = weights.sum
      acc = 0.0
      weights.map { |w| acc += w / total }
    end
    cdf.bsearch_index { |c| c >= random.rand } || (n - 1)
  end

  # Artists with albums and tracks. MBID coverage and album-name presence follow what the live
  # probe measured for this account (docs/lastfm-api-findings.md): 66% artist, 66% track, 57%
  # album MBIDs, 75% album names. Some names are non-ASCII.
  def catalogue
    @catalogue ||= begin
      artists = [ (SCROBBLES / 35).clamp(200, 40_000), 200 ].max
      Array.new(artists) do |a|
        name = a % 20 == 0 ? "Artïst #{a} ñ" : "Artist #{a}"
        mbid = random.rand < 0.66 ? SecureRandom.uuid : ""
        albums = Array.new(1 + random.rand(6)) { |b| random.rand < 0.75 ? [ "Album #{a}-#{b}", random.rand < 0.57 ? SecureRandom.uuid : "" ] : [ "", "" ] }
        tracks = Array.new(5 + random.rand(40)) do |t|
          album = albums.sample(random: random)
          [ "Track #{a}-#{t}", random.rand < 0.66 ? SecureRandom.uuid : "", *album ]
        end
        { name: name, mbid: mbid, tracks: tracks }
      end
    end
  end

  # Days from START to T0 with uneven listening: heavier and lighter years, quiet months, a few
  # empty months, sessions of consecutive plays about a track length apart, repeats, and rare
  # same-second duplicates (0.1%).
  def history
    @history ||= begin
      days = ((T0 - 2.days - START) / 1.day).floor
      year_weight = Hash.new { |h, y| h[y] = 0.4 + random.rand * 1.6 }
      empty_months = Set.new(Array.new(6) { [ 2005 + random.rand(18), 1 + random.rand(12) ] })
      day_weights = Array.new(days) do |d|
        t = START + d.days
        empty_months.include?([ t.year, t.month ]) ? 0.0 : year_weight[t.year] * (0.2 + random.rand)
      end
      scale = SCROBBLES / day_weights.sum
      plays = []
      day_weights.each_with_index do |w, d|
        n = (w * scale).round
        at = START + d.days + random.rand(14 * 3600) + 6 * 3600
        last = nil
        n.times do
          artist = catalogue[zipf(catalogue.size)]
          track = random.rand < 0.03 && last ? last : artist[:tracks][zipf(artist[:tracks].size, 0.9)].then { |t| [ artist, t ] }
          last = track
          a, (name, track_mbid, album, album_mbid) = track
          plays << Play.new(at.to_i, a[:name], a[:mbid], name, track_mbid, album, album_mbid)
          plays << plays.last.dup if random.rand < 0.001 # a same-second duplicate
          at += 150 + random.rand(200)
        end
      end
      plays = plays.select { |p| p.at < (T0 - 1.hour).to_i }.first(SCROBBLES)
      plays.sort_by! { |p| -p.at }
    end
  end
end

# An indexed fake of user.getRecentTracks (newest first, `from` inclusive, `to` exclusive, 200 per
# page, `total` and `totalPages` as strings), with request counting and scripted failures.
class IndexedFake
  attr_reader :requests
  attr_accessor :fail_every, :plays

  def initialize(plays)
    @plays = plays # newest first
    @requests = Hash.new(0)
    @fail_every = nil
  end

  def add(play)
    @plays << play
    @plays.sort_by! { |p| -p.at }
  end

  # Plays are newest first: [from, to) is a contiguous slice found by binary search.
  def range(from, to)
    first = to ? (@plays.bsearch_index { |p| p.at < to.to_i } || @plays.size) : 0
    last = from ? (@plays.bsearch_index { |p| p.at < from.to_i } || @plays.size) : @plays.size
    @plays[first...last] || []
  end

  def respond(query)
    @requests[:recent] += 1
    return { status: 502, body: "" } if fail_every && (@requests[:recent] % fail_every).zero?

    limit = Integer(query["limit"] || 50)
    page = Integer(query["page"] || 1)
    selected = range(query["from"], query["to"])
    rows = selected.slice((page - 1) * limit, limit) || []
    track = rows.map do |p|
      { artist: { mbid: p.artist_mbid, "#text" => p.artist }, mbid: p.track_mbid, name: p.track,
        album: { mbid: p.album_mbid, "#text" => p.album }, date: { uts: p.at.to_s, "#text" => "" } }
    end
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { recenttracks: { track: track, "@attr" => { user: Bench::USERNAME, page: page.to_s, perPage: limit.to_s,
                                                          totalPages: (selected.size / limit.to_f).ceil.to_s, total: selected.size.to_s } } }.to_json }
  end
end

# Where time and queries go: each phase is a block; SQL is attributed to the innermost phase.
class Meter
  SLOW = 0.1 # seconds

  attr_reader :phases, :slow

  def initialize
    @phases = Hash.new { |h, k| h[k] = { seconds: 0.0, calls: 0, queries: 0 } }
    @slow = Hash.new { |h, k| h[k] = { count: 0, max_ms: 0 } }
    @stack = []
    ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, start, finish, _id, payload|
      next if payload[:name] == "SCHEMA" || payload[:cached]

      @phases[@stack.last || :other][:queries] += 1
      duration = finish - start
      next unless duration > SLOW

      key = payload[:sql].gsub(/\$\d+|'[^']*'|\b\d+\b/, "?").squish.truncate(140)
      @slow[key][:count] += 1
      @slow[key][:max_ms] = [ @slow[key][:max_ms], (duration * 1000).round ].max
    end
  end

  def measure(phase)
    @stack.push(phase)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    @phases[phase][:seconds] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    @phases[phase][:calls] += 1
    @stack.pop
  end
end

METER = Meter.new
HistoryImport::WindowValidator.prepend(Module.new { def call = METER.measure(:validate) { super } })
HistoryImport::WindowCommitter.prepend(Module.new { def call = METER.measure(:commit) { super } })
HistoryImport::Reconciler.prepend(Module.new do
  def call = METER.measure(:reconcile) { super }

  private

  def verify!(...) = METER.measure(:reconcile_verify) { super }
end)

def rss_mb = (`ps -o rss= -p #{Process.pid}`.to_i / 1024.0).round(1)

def say(line)
  puts line
  $stdout.flush
end

def truncate_history!
  conn = ActiveRecord::Base.connection
  tables = %w[review_decisions reconciliation_disputes scrobble_removals scrobble_corrections catalogue_reviews artist_aliases
              scrobbles import_window_rows import_window_fetches import_windows import_runs name_variants tracks albums artists
              lastfm_connections sessions identities users api_request_slots]
  conn.execute("TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE")
end

# Runs a run's job chain inline, advancing the clock to each scheduled step, as Solid Queue would.
def drive(run, clock, limit: 100_000)
  orchestrator = HistoryImport::Orchestrator.new(clock: -> { clock[:now] })
  steps = 0
  staging_peak = 0
  rss_peak = rss_mb
  limit.times do
    run.reload
    break unless run.working?

    clock[:now] = [ clock[:now], run.next_step_at ].compact.max
    METER.measure(:step) { orchestrator.step!(run.id, run.job_token) }
    steps += 1
    if (steps % 25).zero?
      staging_peak = [ staging_peak, ImportWindowRow.count ].max
      rss_peak = [ rss_peak, rss_mb ].max
    end
  end
  { steps: steps, state: run.reload.state, staging_peak_rows: staging_peak, rss_peak_mb: rss_peak }
end

def timed
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = yield
  [ result, (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(1) ]
end

results = { scrobbles_requested: Bench::SCROBBLES, seed: Bench::SEED, database: DATABASE, failures: Bench::FAILURES }
say "Generating #{Bench::SCROBBLES} synthetic plays (seed #{Bench::SEED})"
plays, results[:generate_seconds] = timed { Bench.history }
results[:plays] = plays.size
results[:artists] = Bench.catalogue.size
results[:distinct_tracks] = plays.map { |p| [ p.artist, p.track, p.album ] }.uniq.size
results[:same_second_duplicates] = plays.size - plays.map { |p| [ p.at, p.artist, p.track, p.album ] }.uniq.size
by_month = plays.group_by { |p| Time.at(p.at).utc.strftime("%Y-%m") }.transform_values(&:size)
results[:months] = { with_plays: by_month.size, max_plays: by_month.values.max, over_4000: by_month.values.count { |n| n > 4000 } }
say "  #{plays.size} plays, #{results[:artists]} artists, #{results[:distinct_tracks]} distinct track strings, busiest month #{by_month.values.max}"

# For the real Solid Queue run (test/smoke/solid_queue/run.rb `large_import`): the same plays.
if (dump = ENV["DUMP_PLAYS"])
  File.binwrite(dump, Marshal.dump(plays.map(&:to_a)))
  say "  plays written to #{dump}"
  exit 0 if ENV["DUMP_ONLY"] == "1"
end

truncate_history!
fake = IndexedFake.new(plays.dup)
WebMock.enable!
WebMock.disable_net_connect!
stub = Object.new.extend(WebMock::API)
stub.stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: WebMock::API.hash_including("method" => "user.getRecentTracks"))
    .to_return { |request| fake.respond(Rack::Utils.parse_query(request.uri.query)) }
stub.stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: WebMock::API.hash_including("method" => "user.getInfo"))
    .to_return do |_request|
      fake.requests[:info] += 1
      { status: 200, body: { user: { name: Bench::USERNAME, playcount: fake.plays.size.to_s, registered: { unixtime: Bench::START.to_i.to_s } } }.to_json }
    end
# Fixed synthetic credentials, whatever the environment holds; nothing leaves the process (WebMock).
ENV["LASTFM_API_KEY"] = "bench-key"
ENV["LASTFM_SHARED_SECRET"] = "bench-secret"
Rails.configuration.x.lastfm_allowed_usernames = [ Bench::USERNAME ]
Rails.configuration.x.lastfm_client_options = { sleeper: ->(_seconds) { } }

user = User.create!(display_name: "Benchmark")
identity = Identity.create!(user: user, provider: Identity::LASTFM, uid: Bench::USERNAME, username: Bench::USERNAME,
                            registered_at: Bench::START, credentials: { "session_key" => "bench-session" })
LastfmConnection.create!(user: user, identity: identity)
clock = { now: Bench::T0 }

# --- 1. Full import ---------------------------------------------------------------------------
if Bench::FAILURES
  fake.fail_every = 33 # about 3% of requests answer 502
  crashed = false
  HistoryImport::WindowCommitter.prepend(Module.new do
    define_method(:commit_under_lease) do
      if !crashed && ImportWindow.imported.count > 20
        crashed = true
        raise Exception, "simulated crash mid-commit" # rubocop:disable Lint/RaiseException -- stands in for a killed worker
      end
      super()
    end
  end)
end
say "Full import"
gc_before = GC.stat(:total_allocated_objects)
run = HistoryImport::Orchestrator.new(clock: -> { clock[:now] }).start!(user)
import, import_seconds = timed do
  begin
    drive(run, clock)
  rescue Exception => e # rubocop:disable Lint/RescueException -- the simulated crash
    raise unless e.message == "simulated crash mid-commit"

    say "  crashed mid-commit as scripted; recovering"
    clock[:now] += ImportWindow::LEASE + HistoryImport::Recovery::STALL_AFTER + 1.minute
    recovery, results[:recovery_seconds] = timed { HistoryImport::Recovery.new(clock: -> { clock[:now] }).run! }
    results[:recovery] = recovery.except(:staging)
    drive(run.reload, clock)
  end
end
fake.fail_every = nil
stored = Scrobble.where(user: user).count
results[:import] = import.merge(seconds: import_seconds, requests: fake.requests.dup, stored: stored,
                                windows: ImportWindow.live.where(user: user).count, split_windows: ImportWindow.where(state: "split").count,
                                allocated_objects_millions: ((GC.stat(:total_allocated_objects) - gc_before) / 1e6).round)
results[:import][:plays_per_second] = (stored / import_seconds).round
say "  #{import[:state]} in #{import_seconds}s (#{import[:steps]} steps), #{stored} stored, #{fake.requests[:recent]} recent-tracks requests"

# Integrity: every play stored once per occurrence, months exact, coverage complete.
expected = plays.group_by { |p| Time.at(p.at).utc.strftime("%Y-%m") }.transform_values(&:size)
actual = Scrobble.where(user: user).group(Arel.sql("to_char(played_at AT TIME ZONE 'UTC', 'YYYY-MM')")).count
results[:integrity] = {
  count_matches: stored == plays.size,
  months_match: expected == actual,
  same_second_slots: Scrobble.where(user: user).where("seq > 0").count,
  coverage: ImportCoverage.status_for(user, ImportWindow.live.where(user: user).minimum(:window_from), Bench::T0.beginning_of_minute),
  committed_counts_match: ImportWindow.live.where(user: user).sum(:committed_count) == stored
}
say "  integrity #{results[:integrity].inspect}"

# --- 2. Catalogue matching ----------------------------------------------------------------------
say "Catalogue matching"
matched, match_seconds = timed do
  total = 0
  METER.measure(:match) do
    loop do
      n = Catalogue::Matcher.new.match_pending!(limit: 2_000)
      total += n
      break if n < 2_000
    end
  end
  total
end
results[:matching] = { variants: matched, seconds: match_seconds, per_second: (matched / [ match_seconds, 0.001 ].max).round,
                       artists: Artist.count, albums: Album.count, tracks: Track.count }
say "  #{matched} variants in #{match_seconds}s"

# STOP_AFTER=matching keeps the imported, matched history for test/benchmark/analytics_benchmark.rb.
if ENV["STOP_AFTER"] == "matching"
  File.write(ENV.fetch("OUT", Rails.root.join("tmp/benchmark-#{Bench::SCROBBLES}.json").to_s), JSON.pretty_generate(results))
  say "Stopped after matching; the history stays for analytics benchmarks"
  exit 0
end

# --- 3. Storage -------------------------------------------------------------------------------
staging_mb = -> { (ActiveRecord::Base.connection.select_value("SELECT pg_total_relation_size('import_window_rows')").to_i / 1_048_576.0).round(1) }
results[:staging_space] = { after_import_mb: staging_mb.call }
HistoryImport::StagingCleaner.new(clock: -> { clock[:now] }).call # what the watchdog does every 10 minutes
results[:staging_space][:after_cleaner_mb] = staging_mb.call
ActiveRecord::Base.connection.execute("VACUUM ANALYZE")
sizes = StorageReport.rows
results[:storage] = {
  tables: sizes.reject { |r| r.rows.zero? && r.bytes < 100_000 }.to_h { |r| [ r.table, { rows: r.rows, mb: (r.bytes / 1_048_576.0).round(2) } ] },
  total_mb: (StorageReport.total_bytes(sizes) / 1_048_576.0).round(1),
  bytes_per_scrobble: (StorageReport.total_bytes(sizes) / [ stored, 1 ].max.to_f).round
}
say "  storage #{results[:storage][:total_mb]} MB (#{results[:storage][:bytes_per_scrobble]} bytes per scrobble)"

# --- 4. Recheck every month (reconciliation of a whole history) ---------------------------------
say "Recheck of every month"
METER.phases[:reconcile_verify] # ensure the key exists
before_reconcile = METER.phases[:reconcile].dup
before_verify = METER.phases[:reconcile_verify].dup
requests_before = fake.requests[:recent]
recheck = HistoryImport::Recheck.request!(user, clock: -> { clock[:now] })
rechecked, recheck_seconds = timed { drive(recheck, clock) }
results[:recheck] = rechecked.merge(seconds: recheck_seconds, requests: fake.requests[:recent] - requests_before,
                                    reconcile_seconds: (METER.phases[:reconcile][:seconds] - before_reconcile[:seconds]).round(1),
                                    verify_seconds: (METER.phases[:reconcile_verify][:seconds] - before_verify[:seconds]).round(1),
                                    unchanged: Scrobble.where(user: user).count == stored && ScrobbleRemoval.none? && ReconciliationDispute.none?)
results[:staging_space][:after_recheck_mb] = staging_mb.call
HistoryImport::StagingCleaner.new(clock: -> { clock[:now] }).call
results[:staging_space][:after_recheck_cleaner_mb] = staging_mb.call
say "  #{recheck_seconds}s; reconcile #{results[:recheck][:reconcile_seconds]}s, of which verification #{results[:recheck][:verify_seconds]}s"
say "  staging space #{results[:staging_space].inspect}"

# --- 5. Synchronisation ------------------------------------------------------------------------
say "Synchronisation"
LastfmConnection.where(user: user).update_all(history_state: "imported")
sync = {}
20.times { |i| fake.add(Bench::Play.new((Bench::T0 + (i * 120)).to_i, "Artist 1", "", "New #{i}", "", "", "")) }
clock[:now] = Bench::T0 + 1.hour
r = HistoryImport::Sync.start!(user, kind: "sync", now: clock[:now])
requests_before = fake.requests[:recent]
out, seconds = timed { drive(r, clock) }
sync[:incremental] = out.merge(seconds: seconds, requests: fake.requests[:recent] - requests_before, added: r.reload.committed_scrobbles)

fake.add(Bench::Play.new((Bench::T0 - 5.days).to_i, "Artist 2", "", "Offline", "", "", ""))
clock[:now] = Bench::T0 + 1.day + 1.hour
r = HistoryImport::Sync.start!(user, kind: "catch_up", now: clock[:now])
requests_before = fake.requests[:recent]
out, seconds = timed { drive(r, clock) }
sync[:catch_up] = out.merge(seconds: seconds, requests: fake.requests[:recent] - requests_before, added: r.reload.committed_scrobbles)

fake.add(Bench::Play.new((Bench::T0 - 3.years).to_i, "Artist 3", "", "Historical", "", "", ""))
clock[:now] = Bench::T0 + 8.days
r = HistoryImport::Sync.start!(user, kind: "reconcile", now: clock[:now])
requests_before = fake.requests[:recent]
out, seconds = timed { drive(r, clock) }
sync[:weekly] = out.merge(seconds: seconds, requests: fake.requests[:recent] - requests_before, added: r.reload.committed_scrobbles)
results[:sync] = sync
say "  #{sync.transform_values { |v| [ v[:seconds], v[:requests], v[:added] ] }.inspect} (seconds, requests, added)"

# --- 6. Status endpoints and background count ----------------------------------------------
def ms
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
end
status = {}
status[:sync_health_ms] = ms { HistoryImport::SyncHealth.for(user) }
status[:import_status_ms] = ms { HistoryImport::ImportStatus.for(user) }
status[:count_check_ms] = ms { HistoryImport::CountCheck.run!(user.id) }
status[:review_queue_ms] = ms { HistoryImport::ReviewQueue.for(user) }
results[:status] = status
say "  status #{status.inspect}"

results[:phases] = METER.phases.transform_values { |v| v.merge(seconds: v[:seconds].round(1)) }
results[:slow_queries] = METER.slow.sort_by { |_, v| -v[:max_ms] }.first(12).to_h
results[:rss_mb_end] = rss_mb
results[:postgres] = { max_connections: ActiveRecord::Base.connection.select_value("SHOW max_connections").to_i,
                       pool_size: ActiveRecord::Base.connection_pool.size }
out = ENV.fetch("OUT", Rails.root.join("tmp/benchmark-#{Bench::SCROBBLES}#{'-failures' if Bench::FAILURES}.json").to_s)
File.write(out, JSON.pretty_generate(results))
say "Results: #{out}"
