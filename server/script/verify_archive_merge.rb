#!/usr/bin/env ruby
# Independent check of a merge (docs/railway-deployment.md §6). Plain Ruby and psql: it shares no
# code with the merge, and doesn't load Rails, so a bug there can't hide here.
#
#   script/verify_archive_merge.rb snapshot DATABASE_URL > before.json       before merging
#   script/verify_archive_merge.rb verify DATABASE_URL before.json export.ndjson   after merging
#
# Exits non-zero if anything fails. Compares every table's existing rows; only what a merge is
# meant to change may change.
require "json"
require "digest"
require "open3"
require "time"

# May change or grow: Spotify's own record, and bookkeeping unrelated to history.
EXCLUDED = %w[listening_observations listening_polls listening_gaps listening_sources sessions api_request_slots schema_migrations ar_internal_metadata].freeze
# A merge writes a variant's match state only on rows it adds. These columns are what identify a variant.
ROW_SQL = { "name_variants" => "variant_hash, artist_name, track_name, album_name, artist_mbid, track_mbid, album_mbid" }.freeze

def psql(url, query)
  out, status = Open3.capture2("psql", url, "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-c", query)
  abort "psql failed: #{query[0, 80]}" unless status.success?
  out.strip
end

def snapshot(url)
  tables = psql(url, "select table_name from information_schema.tables where table_schema='public' and table_type='BASE TABLE' order by 1").split("\n") - EXCLUDED
  tables.to_h do |table|
    has_id = psql(url, "select count(*) from information_schema.columns where table_schema='public' and table_name='#{table}' and column_name='id'") == "1"
    max = has_id ? psql(url, "select coalesce(max(id),0) from #{table}").to_i : nil
    [ table, { "count" => psql(url, "select count(*) from #{table}").to_i, "max_id" => max, "md5" => digest(url, table, max) } ]
  end
end

def digest(url, table, max)
  cols = ROW_SQL[table]
  row = cols ? "row_to_json((select r from (select #{cols}) r))" : "row_to_json(#{table})"
  where = max ? "where id <= #{max}" : ""
  order = max ? "order by id" : "order by #{row}::text"
  psql(url, "select md5(coalesce(string_agg(#{row}::text, E'\\n' #{order}), '')) from #{table} #{where}")
end

case ARGV[0]
when "snapshot"
  url = ARGV[1] or abort "usage"
  puts JSON.pretty_generate("tables" => snapshot(url), "spotify_plays" => psql(url, "select count(*) from scrobbles where source='spotify'").to_i,
                            "observations" => psql(url, "select count(*) from listening_observations").to_i,
                            "last_fm" => psql(url, "select count(*), md5(string_agg(id::text||played_at::text||seq::text||name_variant_id::text, ',' order by id)) from scrobbles where source='lastfm'"))
when "verify"
  url, before_path, export_path = ARGV[1..3]
  abort "usage" unless export_path
  before = JSON.parse(File.read(before_path))
  failures = 0
  check = lambda do |name, ok, detail = nil|
    puts "#{ok ? "PASS" : "FAIL"} #{name}#{"  [#{detail}]" if detail}"
    failures += 1 unless ok
  end

  lines = File.readlines(export_path, chomp: true)
  trailer = JSON.parse(lines.pop)
  check.call("export file intact", trailer["lines"] == lines.size && trailer["sha256"] == Digest::SHA256.hexdigest(lines.join))
  records = lines.map { JSON.parse(_1) }.group_by { _1["type"] }
  exported = records.fetch("observation", [])

  before["tables"].each do |table, was|
    check.call("#{table}: every existing row unchanged", digest(url, table, was["max_id"]) == was["md5"] && (was["max_id"] || psql(url, "select count(*) from #{table}").to_i == was["count"]), "#{was["count"]} rows before, #{psql(url, "select count(*) from #{table}")} now")
  end
  check.call("Last.fm plays and fingerprint unchanged", psql(url, "select count(*), md5(string_agg(id::text||played_at::text||seq::text||name_variant_id::text, ',' order by id)) from scrobbles where source='lastfm'") == before["last_fm"], before["last_fm"][0, 20])

  account = records.fetch("header").first["account"]
  rows = psql(url, "select coalesce(json_agg(json_build_object('id', o.source_event_id, 'raw', o.reported_at_raw, 'state', o.link_state, 'scrobble', o.scrobble_id, 'played', s.played_at, 'source', s.source, 'artist', v.artist_name, 'track', v.track_name, 'album', v.album_name, 'track_id', o.provider_track_id, 'isrc', o.isrc, 'received', o.received_at)), '[]') from listening_observations o join listening_sources src on src.id=o.listening_source_id join name_variants v on v.id=o.name_variant_id left join scrobbles s on s.id=o.scrobble_id where src.provider='spotify' and src.external_account_id='#{account.gsub("'", "''")}'")
  stored = JSON.parse(rows).to_h { [ _1["id"], _1 ] }
  missing = exported.reject { stored.key?(_1["source_event_id"]) }
  check.call("every exported play has its observation", missing.empty?, "#{exported.size} exported, #{missing.size} missing")
  altered = exported.select { |e| (s = stored[e["source_event_id"]]) && !(s["raw"] == e["reported_at_raw"] && s["artist"] == e["artist_name"] && s["track"] == e["track_name"] && s["album"] == e["album_name"] && s["track_id"] == e["provider_track_id"] && s["isrc"] == e["isrc"]) }
  check.call("each observation keeps its exact report", altered.empty?, "#{altered.size} differ")
  later = exported.select { |e| (s = stored[e["source_event_id"]]) && Time.parse("#{s["received"]} UTC") > Time.iso8601(e["received_at"]) + 1 }
  check.call("first-received times kept", later.empty?, "#{later.size} later")
  tally = exported.map { stored[_1["source_event_id"]]&.fetch("state") }.tally
  uncounted = exported.select { (s = stored[_1["source_event_id"]]) && s["state"] != "pending_review" && s["scrobble"].nil? }
  check.call("every play is counted, or visibly held for a person", uncounted.empty?, tally.to_s)
  linked_wrong = exported.select { (s = stored[_1["source_event_id"]]) && s["state"] == "created" && s["source"] != "spotify" }
  check.call("created plays belong to Spotify", linked_wrong.empty?)
  check.call("linked plays keep two sources' reports", exported.none? { (s = stored[_1["source_event_id"]]) && s["state"] == "linked" && s["source"].nil? })
  check.call("no duplicate observations", psql(url, "select count(*) from (select listening_source_id, source_event_id from listening_observations group by 1,2 having count(*)>1) x") == "0")
  check.call("no play counted twice", psql(url, "select count(*) from (select user_id, played_at, seq from scrobbles group by 1,2,3 having count(*)>1) x") == "0")
  check.call("no play with two reports from one provider", psql(url, "select count(*) from (select scrobble_id, provider from listening_observations where scrobble_id is not null group by 1,2 having count(*)>1) x") == "0")
  spotify_now = psql(url, "select count(*) from scrobbles where source='spotify'").to_i
  created_now = psql(url, "select count(*) from listening_observations where link_state='created'").to_i
  check.call("Spotify plays equal created observations", spotify_now == created_now, "#{spotify_now} plays (#{before["spotify_plays"]} before), #{created_now} created")
  polls = records.fetch("poll", []).map { _1.dig("row", "started_at") }
  stored_polls = psql(url, "select count(*) from listening_polls").to_i
  check.call("poll history carried", stored_polls >= polls.size, "#{polls.size} exported, #{stored_polls} stored")
  gaps = records.fetch("gap", []).size
  check.call("gap history carried", psql(url, "select count(*) from listening_gaps").to_i >= gaps, "#{gaps} exported")
  decisions = records.fetch("decision", []).size
  check.call("review decisions carried", psql(url, "select count(*) from review_decisions where subject_type='ListeningObservation'").to_i >= decisions, "#{decisions} exported")
  puts "Catalogue and metadata decisions to review by hand: #{records.fetch("other_decision", []).size}"
  puts failures.zero? ? "VERIFIED" : "FAILED: #{failures}"
  exit(failures.zero? ? 0 : 1)
else
  abort "usage: snapshot URL | verify URL before.json export.ndjson"
end
