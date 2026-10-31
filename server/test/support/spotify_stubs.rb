# Synthetic Spotify responses for WebMock (docs/spotify-plan.md). Nothing reaches Spotify.
module SpotifyStubs
  TOKEN_URL = "https://accounts.spotify.com/api/token".freeze
  API = "https://api.spotify.com/v1".freeze

  def stub_spotify_tokens(access: "access-1", refresh: "refresh-1", scope: "user-read-recently-played", status: 200, body: nil)
    stub_request(:post, TOKEN_URL).to_return(status: status, headers: { "Content-Type" => "application/json" },
                                             body: (body || { access_token: access, token_type: "Bearer", expires_in: 3600,
                                                              refresh_token: refresh, scope: scope }.compact).to_json)
  end

  def stub_spotify_me(id: "spotify-user", name: "Listener")
    stub_request(:get, "#{API}/me").to_return(status: 200, headers: { "Content-Type" => "application/json" },
                                             body: { id: id, display_name: name, type: "user" }.to_json)
  end

  # A Recently Played item. `at`: played_at.
  def spotify_item(at, track: "Song", artist: "Band", album: "Album", duration: 200_000, id: "trk#{track.hash.abs}", isrc: "GBAAA0000001")
    { "played_at" => at.utc.iso8601(3),
      "context" => { "type" => "playlist", "uri" => "spotify:playlist:abc", "href" => "https://api.spotify.com/v1/playlists/abc" },
      "track" => { "type" => "track", "id" => id, "name" => track, "duration_ms" => duration, "external_ids" => { "isrc" => isrc },
                   "artists" => [ { "id" => "art-#{artist}", "name" => artist }, { "id" => "art-feat", "name" => "Guest" } ],
                   "album" => { "id" => "alb-#{album}", "name" => album }, "popularity" => 50 } }
  end
end

ActiveSupport::TestCase.include(SpotifyStubs)
ActionDispatch::IntegrationTest.include(SpotifyStubs)
