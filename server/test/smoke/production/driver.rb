# End-to-end checks of the production image (run.sh starts everything). Plain Ruby: it talks to the
# app over HTTP like a browser, and to PostgreSQL and Docker for what a browser can't see.
require "net/http"
require "uri"
require "json"
require "open3"
require "fileutils"

$failures = 0
HOST = "runout.test"
OLD_HOST = "old.runout.test" # a second configured hostname (APP_ORIGINS), as during a domain change
APP = "runout-smoke-app"
PG = "runout-smoke-pg"
STATE = ENV.fetch("STATE", "/state")
$jar = {}
$set = {}

def check(name, ok, detail = nil)
  puts "#{ok ? "PASS" : "FAIL"} #{name}#{"  [#{detail}]" if detail}"
  $stdout.flush
  $failures += 1 unless ok
end

def req(method, path, headers: {}, host: HOST, body: nil)
  Net::HTTP.start(ENV.fetch("APP_ADDRESS", APP), ENV.fetch("APP_PORT", 3000).to_i, read_timeout: 120) do |http|
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
    request = klass.new(path)
    request["Host"] = host
    request["Cookie"] = $jar.map { |k, v| "#{k}=#{v}" }.join("; ") unless $jar.empty?
    headers.each { |k, v| request[k] = v }
    if body
      request["Content-Type"] = "application/json"
      request.body = body.to_json
    end
    response = http.request(request)
    (response.get_fields("set-cookie") || []).each do |cookie|
      key, value = cookie.split(";").first.split("=", 2)
      value.to_s.empty? ? $jar.delete(key) : $jar[key] = value
      $set[key] = cookie
    end
    response
  end
end

def sql(query, db = "railway") = Open3.capture2("docker", "exec", PG, "psql", "-U", "postgres", "-d", db, "-X", "-A", "-t", "-c", query).first.strip
def docker(*args) = Open3.capture2e("docker", *args).first

def wait_up(max = 180)
  started = Time.now
  loop do
    return Time.now - started if (req(:get, "/up", host: "x").code == "200" rescue false)
    raise "the app did not come up: #{docker("logs", "--tail", "30", APP)}" if Time.now - started > max

    sleep 0.5
  end
end

def polls = sql("select count(*) from listening_polls where outcome='ok'").to_i

def wait_poll(label, max = 420)
  before = polls
  started = Time.now
  sleep 2 until polls > before || Time.now - started > max
  check("poll runs #{label}", polls > before, "#{(Time.now - started).round}s")
end

def memory_mb = (docker("exec", APP, "cat", "/sys/fs/cgroup/memory.current").to_f / 1024 / 1024).round
def pg_memory_mb = (docker("exec", PG, "cat", "/sys/fs/cgroup/memory.current").to_f / 1024 / 1024).round
# Bracketed so the shell and grep running this check don't match their own command lines.
def ruby_processes = docker("exec", APP, "sh", "-c", "grep -l -a -E '^[p]uma |[s]olid-queue' /proc/[0-9]*/cmdline 2>/dev/null | wc -l").strip

def lastfm_sign_in
  location = req(:get, "/api/auth/lastfm")["location"]
  callback = URI.decode_www_form(URI(location).query).to_h["cb"]
  check("Last.fm callback is the https origin", callback.start_with?("https://#{HOST}/api/auth/lastfm/callback"))
  uri = URI(callback)
  req(:get, "#{uri.path}?#{uri.query}&token=t")
end

puts "boot #{wait_up.round(1)}s"
check("/up answers Railway's health check host", req(:get, "/up", host: "healthcheck.railway.app").code == "200")
check("another Host is refused", req(:get, "/", host: "evil.example").code == "403")
home = req(:get, "/")
check("/ serves the frontend", home.code == "200" && home.body.include?('id="root"'))
check("shell: no-cache, noindex", home["cache-control"] == "no-cache" && home["x-robots-tag"].to_s.include?("noindex"))
check("HSTS is on", home["strict-transport-security"].to_s.include?("max-age"))
asset_path = home.body[%r{/assets/[^"]+\.js}]
asset = req(:get, asset_path)
check("digested asset served, cached long", asset.code == "200" && asset["cache-control"].to_s.include?("max-age=3155") && asset["content-type"].to_s.include?("javascript"), asset_path)
check("frontend calls the same-origin API", asset.body.include?('"/api"') || asset.body.include?("/api"))
check("fixtures are not in the bundle", !asset.body.include?("specimenApi"))
check("deep link serves the shell", req(:get, "/settings").body.include?('id="root"'))
check("robots disallow everything", req(:get, "/robots.txt").body.include?("Disallow: /"))
check("missing asset is 404", req(:get, "/assets/nope-123.js").code == "404")
check("unknown API path is 404", req(:get, "/api/nope").code == "404")
%w[overview search plays calendar listening-sources].each { |p| check("/api/#{p} needs a session", req(:get, "/api/#{p}").code == "401") }

check("Solid Queue runs inside Puma: one app process", ruby_processes == "1", ruby_processes)
check("supervisor is async", sql("select count(*) from solid_queue_processes where kind='Supervisor(async)'", "runout_queue") == "1")
check("the 5-minute-schedulable poll is registered", sql("select count(*) from solid_queue_recurring_tasks where key='spotify_poll'", "runout_queue") == "1")
check("no solid_cache tables", sql("select count(*) from information_schema.tables where table_name like 'solid_cache%'") == "0")
check("migrations all applied", sql("select count(*) from schema_migrations").to_i == Dir[File.join(ENV.fetch("MIGRATIONS"), "*.rb")].size, sql("select count(*) from schema_migrations"))
check("genres seeded on first deploy", sql("select count(*) from genres").to_i.positive?)
check("connects through DATABASE_URL (railway db) and derived queue db", sql("select count(*) from pg_stat_activity where datname in ('railway','runout_queue') and application_name <> 'psql'").to_i.positive?)

File.write("#{STATE}/stub_user", "intruder\n")
response = lastfm_sign_in
check("another Last.fm account is refused", !$jar.key?("__Host-runout_session") && response["location"].include?("account_not_allowed"), response["location"])
check("and creates no user", sql("select count(*) from users") == "0")
File.write("#{STATE}/stub_user", "listener\n")
lastfm_sign_in
cookie = $set["__Host-runout_session"].to_s.downcase
check("session cookie: __Host-, Secure, HttpOnly, Lax", cookie.include?("secure") && cookie.include?("httponly") && cookie.include?("samesite=lax") && cookie.include?("path=/"))
check("signed in reaches private data", req(:get, "/api/listening-sources").code == "200")
check("the archive waits for stored plays: 409, not 401", req(:get, "/api/overview").code == "409")
{ "no Origin" => {}, "wrong Origin" => { "Origin" => "https://evil.example", "X-Requested-With" => "XMLHttpRequest" },
  "no XHR header" => { "Origin" => "https://#{HOST}" } }.each do |name, headers|
  check("CSRF: POST with #{name} is refused", req(:post, "/api/listening-sources/spotify/pause", headers: headers).code == "403")
end
check("an unconfigured hostname is blocked", req(:get, "/api/connection", host: "evil.test").code == "403")
check("the second configured hostname answers", req(:get, "/api/connection", host: OLD_HOST).code == "200")
check("CSRF: POST on one hostname with the other's Origin is refused",
      req(:post, "/api/listening-sources/spotify/pause", headers: { "Origin" => "https://#{HOST}", "X-Requested-With" => "XMLHttpRequest" }, host: OLD_HOST).code == "403")
check("Last.fm sign-in on the second hostname moves to the canonical origin first",
      req(:get, "/api/auth/lastfm?tz=UTC", host: OLD_HOST)["location"] == "https://#{HOST}/api/auth/lastfm?tz=UTC")

start = URI(req(:get, "/api/auth/spotify")["location"])
check("Spotify start stays on the origin", start.host == HOST && start.scheme == "https")
authorize = URI(req(:get, "#{start.path}?#{start.query}")["location"])
query = URI.decode_www_form(authorize.query).to_h
check("authorize uses the production callback", query["redirect_uri"] == "https://#{HOST}/api/auth/spotify/callback")
check("OAuth nonce cookie is Secure", $set["runout_spotify_auth"].to_s.downcase.include?("secure"))
check("forged state is refused", req(:get, "/api/auth/spotify/callback?state=wrong&code=c")["location"].include?("spotify_error=state"))
req(:get, "#{start.path}?#{start.query}")
check("OAuth callback connects", req(:get, "/api/auth/spotify/callback?#{URI.encode_www_form(state: query["state"], code: "c")}")["location"].include?("spotify=connected"))
check("Spotify tokens encrypted at rest", sql("select count(*) from listening_sources where credentials::text like '%STUB%'") == "0" && sql("select count(*) from listening_sources where credentials is not null") == "1")
check("Last.fm key encrypted at rest", sql("select count(*) from identities where to_jsonb(identities)::text like '%STUBLASTFM%'") == "0")

# A second, invited, Spotify-only account beside the owner's (docs/multi-user-plan.md §5): the
# invitation link, isolation on every answer, its own Spotify account, its own plays, and a deletion
# that leaves the owner untouched. Passkey enrolment needs a browser: the Rails integration test
# and the rehearsal cover it.
SAME_ORIGIN = { "Origin" => "https://#{HOST}", "X-Requested-With" => "XMLHttpRequest" }.freeze
owner_jar = $jar.dup
invite = docker("exec", APP, "bin/rails", "auth:invite_link[Dana,America/Los_Angeles]")
link = invite[%r{https://#{HOST}/api/auth/link/[A-Za-z0-9_-]{43}}]
check("the invitation task prints a single-use link", !link.nil?, invite.lines.first.to_s.strip[0, 120])
$jar = {}
response = req(:get, URI(link).path)
check("the invitation signs in and lands on /welcome", response["location"].to_s.end_with?("/welcome") && $jar.key?("__Host-runout_session"), response["location"])
check("a used invitation is refused", req(:get, URI(link).path)["location"].to_s.include?("link_invalid"))
session = JSON.parse(req(:get, "/api/session").body)
check("the invited account has no passkey, no codes, no Last.fm", session["methods"] == { "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false }, session.to_json)
check("the invited account's connection is its own, without Last.fm", JSON.parse(req(:get, "/api/connection").body).values_at("status", "displayName") == [ "none", "Dana" ])
check("the invited account's archive is empty: 409, never the owner's plays", req(:get, "/api/overview").code == "409")
check("the invited account sees only its own browser session", JSON.parse(req(:get, "/api/sessions").body)["sessions"].size == 1)
check("the invited account sees no Spotify connection", JSON.parse(req(:get, "/api/listening-sources").body).dig("spotify", "state") == "not_connected")
start = URI(req(:get, "/api/auth/spotify")["location"])
authorize = URI(req(:get, "#{start.path}?#{start.query}")["location"])
query = URI.decode_www_form(authorize.query).to_h
check("the owner's Spotify account cannot be connected to the invited user",
      req(:get, "/api/auth/spotify/callback?#{URI.encode_www_form(state: query["state"], code: "c")}")["location"].to_s.include?("spotify_error=account_taken"))
check("and the owner's source is untouched", sql("select count(*) from listening_sources where external_account_id='stub-account' and state='connected'") == "1")
File.write("#{STATE}/stub_spotify_account", "stub-dana\n")
sleep 61 # the OAuth routes allow 10 requests a minute per address, and the owner's flow above used most of them
start = URI(req(:get, "/api/auth/spotify")["location"])
authorize = URI(req(:get, "#{start.path}?#{start.query}")["location"])
query = URI.decode_www_form(authorize.query).to_h
check("the invited user connects their own Spotify account",
      req(:get, "/api/auth/spotify/callback?#{URI.encode_www_form(state: query["state"], code: "c")}")["location"].to_s.include?("spotify=connected"))
File.write("#{STATE}/stub_spotify_account", "stub-account\n")
dana_id = sql("select id from users where display_name='Dana'")
check("the invited user's source belongs to them", sql("select count(*) from listening_sources where external_account_id='stub-dana' and user_id='#{dana_id}'") == "1")
if ENV["INGESTION"] != "false"
  started = Time.now
  dana_polls = -> { sql("select count(*) from listening_polls p join listening_sources s on s.id = p.listening_source_id where s.external_account_id='stub-dana' and p.outcome='ok'").to_i }
  sleep 2 until dana_polls.call.positive? || Time.now - started > 420
  check("the invited user's first poll runs", dana_polls.call.positive?, "#{(Time.now - started).round}s")
  dana_plays = sql("select count(*) from scrobbles where user_id='#{dana_id}'").to_i
  check("the invited user's first plays are recorded on their account", dana_plays.positive?, dana_plays)
  check("every one of them is theirs, through their own source", sql("select count(*) from listening_observations o join listening_sources s on s.id = o.listening_source_id where o.user_id='#{dana_id}' and s.user_id<>'#{dana_id}'") == "0")
  check("the invited user's Overview opens on their own plays", req(:get, "/api/overview?period=all").code == "200")
  check("the owner's plays never carry the invited user's id", sql("select count(*) from scrobbles where user_id='#{dana_id}' and source<>'spotify'") == "0")
end
owner_before = %w[scrobbles listening_observations listening_sources sessions identities].to_h { |t| [ t, sql("select count(*) from #{t} where user_id<>'#{dana_id}'") ] }
check("deleting the invited account needs the right name", req(:delete, "/api/account", headers: SAME_ORIGIN, body: { confirm_name: "someone" }).code == "422")
check("the invited user deletes their own account", req(:delete, "/api/account", headers: SAME_ORIGIN, body: { confirm_name: "Dana" }).code == "200")
check("nothing of theirs remains", %w[users scrobbles listening_observations listening_sources listening_polls sessions sign_in_links].all? { |t| sql("select count(*) from #{t} where #{t == 'users' ? 'id' : 'user_id'}='#{dana_id}'") == "0" })
owner_after = %w[scrobbles listening_observations listening_sources sessions identities].to_h { |t| [ t, sql("select count(*) from #{t} where user_id<>'#{dana_id}'") ] }
check("the owner's rows are exactly as before", owner_before == owner_after, "#{owner_before} #{owner_after}")
$jar = owner_jar
check("the owner is still signed in", req(:get, "/api/listening-sources").code == "200")

if ENV["INGESTION"] == "false"
  sleep 75
  check("with ingestion off the tick stores nothing", sql("select count(*) from scrobbles") == "0" && polls.zero?)
  puts "FAILS=#{$failures}"
  exit($failures.zero? ? 0 : 1)
end

wait_poll("from the recurring schedule")
puts "plays #{sql("select count(*) from scrobbles")}"
{ "/api/connection" => 200, "/api/listening-sources" => 200, "/api/overview?period=all" => 200, "/api/search?q=Song" => 200, "/api/calendar" => 200,
  "/api/plays?period=year:#{Time.now.utc.year}" => 200, "/api/on-this-day?date=#{Time.now.utc.strftime("%F")}" => 200 }.each do |path, code|
  check("GET #{path}", req(:get, path).code == code.to_s)
end
idle_mb = memory_mb
pg_mb = pg_memory_mb
wait_poll("again")

# As PID 1 in a container Puma can't re-raise SIGTERM to itself, so its exit code is 1 rather than
# 143 after a graceful stop. What matters is that it and Solid Queue stop cleanly, within Railway's
# draining time (30 s here; after that Docker, like Railway, sends SIGKILL).
started = Time.now
docker("stop", "-t", "30", APP)
took = Time.now - started
logs = docker("logs", APP)
check("SIGTERM stops Puma and Solid Queue gracefully, within draining time",
      took < 30 && logs.include?("Gracefully stopping") && logs.include?("Supervisor terminated gracefully"),
      "#{took.round(1)}s, exit #{docker("inspect", "-f", "{{.State.ExitCode}}", APP).strip}")
docker("start", APP); wait_up; wait_poll("after a graceful restart")
docker("kill", APP)
docker("start", APP); wait_up; wait_poll("after SIGKILL")
killed = sql("select count(*) from (select pg_terminate_backend(pid) from pg_stat_activity where datname in ('railway','runout_queue') and pid <> pg_backend_pid()) x")
puts "dropped #{killed} database connections"
wait_poll("after database connections dropped")
check("the app still serves", req(:get, "/api/connection").code == "200")
docker("restart", PG)
sleep 1 until sql("select 1") == "1"
wait_poll("after a database restart")

check("no duplicate observations", sql("select count(*) from (select listening_source_id, source_event_id from listening_observations group by 1,2 having count(*) > 1) x") == "0")
check("no duplicate plays", sql("select count(*) from (select user_id, played_at, seq from scrobbles group by 1,2,3 having count(*) > 1) x") == "0")
observations = sql("select count(*) from listening_observations")
plays = sql("select count(*) from scrobbles")
span = sql("select (extract(epoch from max(played_at)-min(played_at))/20)::int + 1 from scrobbles")
check("exactly one play per reported event, no gaps", observations == plays && plays == span, "observations=#{observations} plays=#{plays} span=#{span}")
check("source identity kept on every play", sql("select count(*) from scrobbles s join listening_observations o on o.scrobble_id = s.id where s.source = 'spotify' and o.provider = 'spotify'") == plays)
check("repeat reports were recognised", sql("select count(*) from listening_observations where times_seen > 1").to_i.positive?)
check("sign out", req(:delete, "/api/session", headers: { "Origin" => "https://#{HOST}", "X-Requested-With" => "XMLHttpRequest" }).code.start_with?("2"))
check("session is gone", req(:get, "/api/overview").code == "401")
requests = File.read("#{STATE}/stub.log")
check("Last.fm: only the sign-in calls", requests.scan("/2.0/").size == 4, "#{requests.scan("/2.0/").size} calls")
logs = docker("logs", APP)
check("no MusicBrainz or artwork activity", !logs.match?(/musicbrainz|coverartarchive/i) && sql("select count(*) from metadata_fetches") == "0")
check("no errors logged", !logs.match?(/\b(FATAL|Exception|PG::)\b/), logs.lines.grep(/\b(FATAL|Exception|PG::)\b/).first.to_s[0, 150])
puts "MEMORY app_after_requests=#{idle_mb}MB app_now=#{memory_mb}MB postgres=#{pg_mb}MB"
puts "FAILS=#{$failures}"
exit($failures.zero? ? 0 : 1)
