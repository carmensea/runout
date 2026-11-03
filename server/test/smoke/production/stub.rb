# Fake Spotify and Last.fm for test/smoke/production. Network aliases send the real hostnames here,
# on an internal Docker network with no route to the internet, so nothing can reach the real services.
require "socket"
require "openssl"
require "json"
require "time"
require "uri"

Dir.chdir(ENV.fetch("STUB_STATE", "/state"))
context = OpenSSL::SSL::SSLContext.new
context.cert = OpenSSL::X509::Certificate.new(File.read("stub.crt"))
context.key = OpenSSL::PKey.read(File.read("stub.key"))
server = OpenSSL::SSL::SSLServer.new(TCPServer.new("0.0.0.0", ENV.fetch("STUB_PORT", 443).to_i), context)
LOG = File.open("stub.log", "a").tap { |f| f.sync = true }
START = Time.now.to_i - 3000
STEP = 20

# One play every 20 seconds, on a fixed clock, so overlapping polls report identical plays.
def plays
  newest = (Time.now.to_i - START) / STEP
  (newest - 49..newest).map do |i|
    { "played_at" => Time.at(START + i * STEP).utc.iso8601(3), "context" => nil,
      "track" => { "type" => "track", "id" => "trk#{i}", "name" => "Song #{i}", "duration_ms" => 15_000,
                   "external_ids" => { "isrc" => "GBAAA#{i}" }, "artists" => [ { "id" => "art1", "name" => "Stub Band" } ],
                   "album" => { "id" => "alb1", "name" => "Stub Album" } } }
  end.reverse
end

def user = File.read("stub_user").strip

loop do
  socket = begin
    server.accept
  rescue OpenSSL::SSL::SSLError
    next
  end
  Thread.new(socket) do |client|
    line = client.gets or next
    length = 0
    while (header = client.gets) && header != "\r\n"
      length = $1.to_i if header =~ /content-length: (\d+)/i
    end
    client.read(length) if length.positive?
    path = line.split[1]
    query = URI.decode_www_form(path.split("?", 2)[1].to_s).to_h
    LOG.puts "#{path.split("?").first} #{query["method"]}"
    body = case path
    when %r{/api/token} then { access_token: "STUBACCESS", refresh_token: "STUBREFRESHSECRET", scope: "user-read-recently-played", expires_in: 3600, token_type: "Bearer" }
    when %r{/v1/me/player} then { items: plays, next: nil, cursors: nil, limit: 50 }
    when %r{/v1/me} then { id: "stub-account", display_name: "Stub" }
    when %r{/2\.0} then query["method"] == "auth.getSession" ? { session: { name: user, key: "STUBLASTFMKEY", subscriber: 0 } } : { user: { name: user, url: "https://www.last.fm/user/x", playcount: "0", registered: { unixtime: 1199145600 } } }
    else {}
    end.to_json
    client.write "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"
    client.close
  rescue StandardError => e
    LOG.puts "error #{e.class}"
  end
end
