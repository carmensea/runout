# Real Solid Queue smoke test: shared set-up for the driver (run.rb) and its worker processes
# (worker.rb). Synthetic data only, in the disposable database `runout_smoke`, never development.
#
#   createdb runout_smoke  (or bin/rails db:create with the variables below), then load
#   db/schema.rb and db/queue_schema.rb into it; see test/smoke/solid_queue/run.rb.
#
# Last.fm is faked with WebMock, installed before Solid Queue forks its workers, so every process
# serves the same synthetic history. The driver steers the fake through control.json (delays,
# failures, crashes) and reads requests.log, which records every request with its process id.

abort "smoke: RAILS_ENV must be test" unless Rails.env.test?
SMOKE_DATABASE = "runout_smoke".freeze
database = ActiveRecord::Base.connection.current_database
abort "smoke: refusing to run against #{database}; only #{SMOKE_DATABASE}" unless database == SMOKE_DATABASE

require "webmock"
require Rails.root.join("test/support/fake_recent_tracks").to_s

module Smoke
  DIR = ENV.fetch("SMOKE_DIR")
  USERNAME = "smoke-listener".freeze

  module_function

  def control
    JSON.parse(File.read(File.join(DIR, "control.json")))
  rescue Errno::ENOENT, JSON::ParserError
    {}
  end

  def write_control(values) = File.write(File.join(DIR, "control.json"), values.to_json)

  def log(entry)
    File.open(File.join(DIR, "requests.log"), "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts(entry.merge(pid: Process.pid, at: Time.now.to_f).to_json)
    end
  end

  def requests
    File.readlines(File.join(DIR, "requests.log")).map { |line| JSON.parse(line) }
  rescue Errno::ENOENT
    []
  end

  def mark(name) = File.write(File.join(DIR, name), Process.pid.to_s)
  def marked?(name) = File.exist?(File.join(DIR, name))

  # A large synthetic history (SMOKE_PLAYS: a file written by test/benchmark/history_benchmark.rb
  # with DUMP_PLAYS), served by binary search instead of rebuilding the list per request.
  def large? = ENV["SMOKE_PLAYS"].present?

  def large_plays
    @large_plays ||= Marshal.load(File.binread(ENV.fetch("SMOKE_PLAYS"))) # rubocop:disable Security/MarshalLoad -- a file this harness wrote
                            .map { |at, artist, artist_mbid, track, track_mbid, album, album_mbid| [ at, artist, artist_mbid, track, track_mbid, album, album_mbid ] }
                            .sort_by { |row| -row.first }
  end

  def large_registered_at = Time.at(large_plays.last.first).utc.beginning_of_month

  # [from, to) of newest-first rows, as a contiguous slice.
  def large_page(query)
    rows = large_plays
    first = query["to"] ? (rows.bsearch_index { |r| r.first < query["to"].to_i } || rows.size) : 0
    last = query["from"] ? (rows.bsearch_index { |r| r.first < query["from"].to_i } || rows.size) : rows.size
    selected = rows[first...last] || []
    limit = Integer(query["limit"] || 50)
    page = Integer(query["page"] || 1)
    track = (selected.slice((page - 1) * limit, limit) || []).map do |at, artist, artist_mbid, name, track_mbid, album, album_mbid|
      { artist: { mbid: artist_mbid, "#text" => artist }, mbid: track_mbid, name: name, album: { mbid: album_mbid, "#text" => album },
        date: { uts: at.to_s, "#text" => "" } }
    end
    { status: 200, headers: { "Content-Type" => "application/json" },
      body: { recenttracks: { track: track, "@attr" => { user: USERNAME, page: page.to_s, perPage: limit.to_s,
                                                          totalPages: (selected.size / limit.to_f).ceil.to_s, total: selected.size.to_s } } }.to_json }
  end

  def base = Time.now.utc.beginning_of_month - 4.months
  def registered_at = base + 2.days

  # The synthetic history: two pages in the oldest month, an empty month, identical plays in one
  # second, a third month, and a few plays in the current month. The same in every process.
  def plays
    play = ->(at, track, artist = "Smoke Artist") do
      FakeRecentTracks::Play.new(played_at: at.change(usec: 0), artist: artist, track: track, album: "",
                                 artist_mbid: "", track_mbid: "", album_mbid: "")
    end
    list = Array.new(300) { |i| play.(base + 3.days + (i * 600), "Old #{i % 50}", "Smoke Artist #{i % 6}") }
    same = base + 2.months + 4.days
    list += [ play.(same, "Twice"), play.(same, "Twice"), play.(same, "Twice"), play.(same + 60, "After") ]
    list += Array.new(60) { |i| play.(base + 3.months + 1.day + (i * 900), "Third #{i}") }
    list += Array.new(3) { |i| play.(Time.now.utc.beginning_of_month + (i * 60), "Now #{i}") }
    list.select { |p| p.played_at < Time.now - 120 }
  end

  # What Last.fm returns now: the history above, changed as control.json says ("rename":
  # [[unix, old track, new track]], "drop": [[unix, track]], "add": [[unix, track]]).
  def served_plays(control = self.control)
    list = plays.map(&:dup)
    Array(control["rename"]).each do |at, old, new|
      list.find { |p| p.played_at.to_i == at && p.track == old }&.then { |p| p.track = new }
    end
    Array(control["drop"]).each { |at, track| list.delete_at(list.index { |p| p.played_at.to_i == at && p.track == track } || list.size) }
    Array(control["add"]).each do |at, track|
      list << FakeRecentTracks::Play.new(played_at: Time.at(at).utc, artist: "Smoke Artist", track: track, album: "",
                                         artist_mbid: "", track_mbid: "", album_mbid: "")
    end
    list
  end
end

ENV["LASTFM_API_KEY"] = "smoke-api-key"
ENV["LASTFM_SHARED_SECRET"] = "smoke-shared-secret"
Rails.configuration.x.lastfm_allowed_usernames = [ Smoke::USERNAME ]
ActiveJob::Base.queue_adapter = :solid_queue

WebMock.enable!
WebMock.disable_net_connect!
stub = Object.new.extend(WebMock::API)
stub.stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: WebMock::API.hash_including("method" => "user.getRecentTracks"))
    .to_return do |request|
      query = Rack::Utils.parse_query(request.uri.query)
      control = Smoke.control
      Smoke.log(method: "user.getRecentTracks", from: query["from"].to_i, page: query["page"].to_i)
      sleep(control["delay"].to_f) if control["delay"]
      if Smoke.large?
        Smoke.large_page(query)
      elsif Array(control["fail_from"]).include?(query["from"].to_i) || control["fail_all"]
        { status: 502, body: "" }
      elsif (bad = control["undated_at"]) && query["from"] && (query["from"].to_i...query["to"].to_i).cover?(bad)
        # A row Last.fm can't date, in any range that holds that second.
        { status: 200, body: { recenttracks: { "@attr" => { page: "1", perPage: "200", totalPages: "1", total: "1" },
                                               track: [ { artist: { "#text" => "A" }, name: "No date" } ] } }.to_json }
      elsif control["rate_limited"]
        { status: 429, body: { error: 29, message: "Rate Limit Exceeded" }.to_json }
      else
        FakeRecentTracks.new(Smoke.served_plays(control), username: Smoke::USERNAME).respond(query)
      end
    end
stub.stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: WebMock::API.hash_including("method" => "user.getInfo"))
    .to_return do |_request|
      Smoke.log(method: "user.getInfo")
      playcount = Smoke.large? ? Smoke.large_plays.size : Smoke.plays.size
      registered = Smoke.large? ? Smoke.large_registered_at : Smoke.registered_at
      { status: 200, body: { user: { name: Smoke::USERNAME, playcount: playcount.to_s, registered: { unixtime: registered.to_i.to_s } } }.to_json }
    end
