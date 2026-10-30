# A synthetic user.getRecentTracks, served through WebMock. It reproduces the behaviour verified
# against the live API (docs/lastfm-api-findings.md) and can be switched to other behaviours, so
# tests can check that code responds to what the API does rather than to what we assume.
#
# Verified defaults: newest first; `from` inclusive, `to` exclusive; @attr page/perPage/totalPages/
# total as strings; a page past the end has no rows; an empty range reports total 0, totalPages 0.
class FakeRecentTracks
  Play = Struct.new(:played_at, :artist, :track, :album, :artist_mbid, :track_mbid, :album_mbid, keyword_init: true)

  attr_reader :requests, :plays
  attr_accessor :to_inclusive, :now_playing, :rate_limit_after, :shuffle_same_second

  # Scripting for tests: before_request.call(request_number, fake) runs before each response and may
  # mutate the history; fail_requests maps a request number to a raw response to return instead;
  # fail_when.call(query) may return a raw response for any request (for example, one period).
  attr_accessor :before_request, :fail_requests, :fail_when

  def initialize(plays, username: "listener")
    @plays = plays.sort_by { |p| -p.played_at.to_i }
    @username = username
    @to_inclusive = false
    @now_playing = false
    @rate_limit_after = nil
    @requests = 0
    @shuffle_same_second = false
    @fail_requests = {}
    @random = Random.new(1)
  end

  def add(play)
    @plays << play
    @plays.sort_by! { |p| -p.played_at.to_i }
  end

  def remove_if(&block)
    @plays.reject!(&block)
  end

  def replace_at(index, **changes)
    @plays[index] = @plays[index].dup.tap { |p| changes.each { |k, v| p[k] = v } }
  end

  # Builds `count` plays one minute apart, ending at `ending`, with a few same-second pairs.
  def self.history(count:, ending: Time.utc(2020, 6, 1, 12), same_second_every: 25)
    plays = []
    count.times do |i|
      at = ending - (i * 60)
      at = plays.last.played_at if same_second_every && i.positive? && (i % same_second_every).zero?
      plays << Play.new(played_at: at, artist: "Artist #{i % 7}", track: "Track #{i}", album: (i % 4).zero? ? "" : "Album #{i % 5}",
                        artist_mbid: i.even? ? "artist-mbid-#{i % 7}" : "", track_mbid: "", album_mbid: "")
    end
    new(plays)
  end

  def install(test)
    fake = self
    test.stub_request(:get, Lastfm::Client::API_URL.to_s)
        .with(query: WebMock::API.hash_including("method" => "user.getRecentTracks"))
        .to_return { |request| fake.respond(Rack::Utils.parse_query(request.uri.query)) }
    self
  end

  def respond(query)
    @requests += 1
    before_request&.call(@requests, self)
    return fail_requests[@requests] if fail_requests.key?(@requests)
    if fail_when && (failure = fail_when.call(query))
      return failure
    end

    if rate_limit_after && @requests > rate_limit_after
      return json({ error: 29, message: "Rate Limit Exceeded" }, status: 429)
    end

    limit = (query["limit"] || 50).to_i
    page = (query["page"] || 1).to_i
    selected = @plays.select { |p| in_range?(p.played_at.to_i, query["from"], query["to"]) }
    if shuffle_same_second
      # Newest first by second, but plays within one second in a random order on every request.
      selected = selected.group_by { |p| p.played_at.to_i }.sort_by { |second, _| -second }.flat_map { |_, group| group.shuffle(random: @random) }
    end
    total_pages = (selected.size / limit.to_f).ceil
    rows = selected.slice((page - 1) * limit, limit) || []
    tracks = rows.map { |p| entry(p) }
    tracks.unshift(now_playing_entry) if now_playing && page == 1 && query["to"].nil?
    json({ recenttracks: { track: tracks, "@attr" => { user: @username, totalPages: total_pages.to_s, page: page.to_s,
                                                       perPage: limit.to_s, total: selected.size.to_s } } })
  end

  private

  def in_range?(t, from, to)
    return false if from && t < from.to_i
    return false if to && (to_inclusive ? t > to.to_i : t >= to.to_i)

    true
  end

  def entry(play)
    {
      artist: { mbid: play.artist_mbid, "#text" => play.artist }, streamable: "0", image: [], mbid: play.track_mbid,
      album: { mbid: play.album_mbid, "#text" => play.album }, name: play.track, url: "https://www.last.fm/music/x",
      date: { uts: play.played_at.to_i.to_s, "#text" => play.played_at.strftime("%d %b %Y, %H:%M") }
    }
  end

  def now_playing_entry
    { artist: { mbid: "", "#text" => "Live Artist" }, mbid: "", album: { mbid: "", "#text" => "" }, name: "Live Track",
      "@attr" => { nowplaying: "true" } }
  end

  def json(body, status: 200)
    { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" } }
  end
end
