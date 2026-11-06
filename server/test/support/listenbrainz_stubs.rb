# Synthetic ListenBrainz responses for WebMock. Nothing reaches ListenBrainz.
module ListenbrainzStubs
  API = "https://api.listenbrainz.org/1/user".freeze

  # Serves `all` (newest first) the way ListenBrainz does: at most `count` strictly before `max_ts`
  # and strictly after `min_ts`.
  def stub_listens(name, all, count: 1000, status: 200, headers: {})
    stub_request(:get, %r{#{API}/#{name}/listens}).to_return do |request|
      query = Rack::Utils.parse_query(URI(request.uri).query)
      page = all
      page = page.select { |l| l["listened_at"].to_i < query["max_ts"].to_i } if query["max_ts"]
      page = page.select { |l| l["listened_at"].to_i > query["min_ts"].to_i } if query["min_ts"]
      page = page.first([ query["count"].to_i, count ].min)
      body = status == 200 ? { payload: { count: page.size, user_id: name, listens: page } } : { error: "nope", code: status }
      { status: status, body: body.to_json, headers: { "Content-Type" => "application/json" }.merge(headers) }
    end
  end

  def stub_listen_count(name, count)
    stub_request(:get, "#{API}/#{name}/listen-count").to_return(status: 200, body: { payload: { count: count } }.to_json,
                                                                headers: { "Content-Type" => "application/json" })
  end
end
