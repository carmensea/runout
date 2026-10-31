# Milestone 4 benchmark: the Overview's genre and artist-metadata figures and a genre's drill-down,
# on a synthetic history written straight into a disposable database: identified artists, plays,
# and MusicBrainz-like genres for 60% of the artists (classified with the seeded taxonomy).
# Synthetic data only.
#
#   export RAILS_ENV=test DATABASE_URL="postgres://postgres@localhost/runout_smoke?gssencmode=disable"
#   SCROBBLES=1000000 bin/rails runner test/benchmark/genre_benchmark.rb
abort "benchmark: RAILS_ENV must be test" unless Rails.env.test?
DATABASE = ActiveRecord::Base.connection.current_database
abort "benchmark: refusing to run against #{DATABASE}" unless %w[runout_smoke runout_bench].include?(DATABASE)
ActiveRecord::Base.connection_pool.disable_query_cache!

SCROBBLES = Integer(ENV.fetch("SCROBBLES", "209000"))
conn = ActiveRecord::Base.connection
tables = %w[genre_classifications metadata_artworks metadata_tags metadata_artists metadata_targets metadata_fetches metadata_overrides
            catalogue_inferences mbid_disputes review_decisions reconciliation_disputes scrobble_removals scrobble_corrections
            catalogue_reviews artist_aliases scrobbles import_window_rows import_window_fetches import_windows import_runs
            name_variants tracks albums artists lastfm_connections sessions identities users]
conn.execute("TRUNCATE #{tables.join(', ')} RESTART IDENTITY CASCADE")
Genres::Seed.new.apply!

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
user_id = conn.select_value("INSERT INTO users (display_name, reporting_timezone, created_at, updated_at) VALUES ('Benchmark', 'America/Los_Angeles', now(), now()) RETURNING id")
variants = [ SCROBBLES / 10, 1000 ].max
artists = [ variants / 7, 100 ].max
conn.execute(<<~SQL)
  INSERT INTO artists (name, normalized_name, mbid, created_at, updated_at)
  SELECT 'Artist ' || g, 'artist ' || g, md5('artist-' || g)::uuid::text, now(), now() FROM generate_series(1, #{artists}) g
SQL
conn.execute(<<~SQL)
  INSERT INTO name_variants (variant_hash, artist_name, track_name, album_name, artist_id, artist_match, match_version, created_at)
  SELECT sha256(convert_to('bench-' || g, 'UTF8')), 'Artist ' || (1 + g % #{artists}), 'Track ' || g, 'Album ' || (g / 9), 1 + g % #{artists}, 'mbid', 1, now()
    FROM generate_series(1, #{variants}) g
SQL
conn.execute(<<~SQL)
  INSERT INTO scrobbles (user_id, played_at, seq, name_variant_id, created_at)
  SELECT '#{user_id}', timestamp '2006-01-01' + (sqrt(g::float / #{SCROBBLES}) * interval '20 years'), 0,
         1 + floor(power(random(), 2) * #{variants})::int, now()
    FROM generate_series(1, #{SCROBBLES}) g
  ON CONFLICT DO NOTHING
SQL
# Provider metadata and genres for 60% of the artists, from the seeded genre names.
names = TagGenreMapping.distinct.pluck(:tag)
mbids = conn.select_rows("SELECT id, mbid FROM artists WHERE id % 5 < 3").to_h
rng = Random.new(2026)
now = Time.current
MetadataArtist.insert_all!(mbids.map do |id, mbid|
  { provider: "musicbrainz", provider_id: mbid, name: "Artist #{id}", artist_type: id.even? ? "Group" : "Person", gender: id % 3 == 0 ? "Female" : nil,
    core_license: "CC0-1.0", source_url: "https://musicbrainz.org/ws/2/artist/#{mbid}", fetched_at: now, created_at: now, updated_at: now }
end)
MetadataTag.insert_all!(mbids.flat_map do |_, mbid|
  names.sample(rng.rand(1..6), random: rng).map do |n|
    { provider: "musicbrainz", entity_kind: "artist", provider_id: mbid, kind: "genre", name: n, votes: rng.rand(1..20),
      license: "CC-BY-NC-SA-3.0", fetched_at: now, created_at: now, updated_at: now }
  end
end)
conn.execute("ANALYZE")
t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
Genres::Classifications.recompute!
classify_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
user = User.find(user_id)
puts format("history: %d plays, %d artists (%d with genres), written in %.1f s; classifying every artist %d ms",
            Scrobble.count, artists, mbids.size, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, classify_ms)

def measure(runs: 3)
  times = Array.new(runs) do
    t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t) * 1000).round
  end
  { median_ms: times.sort[runs / 2], max_ms: times.max }
end

period = ->(raw) { Analytics::Period.parse(raw, time_zone: user.reporting_timezone, today: Date.new(2026, 1, 1)) }
overview = ->(raw) { Analytics::Overview.new(user: user, period: period.(raw)).call }
%w[all year:2024 month:2024-03].each do |raw|
  with = measure { overview.(raw) }
  puts format("%-34s %s", "overview #{raw}, with genres", with.inspect)
end
genres = Analytics::Overview.instance_method(:genres)
metadata = Analytics::Overview.instance_method(:artist_metadata)
Analytics::Overview.define_method(:genres) { nil }
Analytics::Overview.define_method(:artist_metadata) { nil }
%w[all year:2024].each { |raw| puts format("%-34s %s", "overview #{raw}, without", measure { overview.(raw) }.inspect) }
Analytics::Overview.define_method(:genres, genres)
Analytics::Overview.define_method(:artist_metadata, metadata)
%w[all year:2024].each do |raw|
  puts format("%-34s %s", "genre detail rock #{raw}", measure { Analytics::GenreDetail.new(user: user, period: period.(raw), slug: "rock").call }.inspect)
end
o = overview.("all")[:genres][:broad]
puts "check: shares + unclassified = #{(o[:categories].sum { |c| c[:share] } + o[:untaggedShare]).round(9)}"
