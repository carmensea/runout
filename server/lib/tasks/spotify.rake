# Read-only Spotify checks (docs/spotify-plan.md §4, §9). Nothing here stores plays: the only write
# is the refreshed access token on the connected source.
namespace :spotify do
  def spotify_source
    sources = ListeningSource.spotify.active
    sources = sources.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?
    sources.count == 1 ? sources.first : abort("spotify: expected one connected Spotify source, found #{sources.count} (set USER_ID)")
  end

  def spotify_pages(account, source, pages:)
    items = []
    cursor = nil
    pages.times do |i|
      data = account.with_token(source) { |token| account.client.recently_played(token, limit: 50, before: cursor) }
      batch = Array(data["items"])
      puts format("  page %d: %d items, next: %s, cursors: %s", i + 1, batch.size, data["next"] ? "yes" : "none", data["cursors"]&.keys.inspect)
      items.concat(batch)
      cursor = data.dig("cursors", "before")
      break if batch.empty? || cursor.blank? || data["next"].blank?
    end
    items
  end

  desc "Read-only: the connected account, and how far back Recently Played reaches (PAGES=5)"
  task verify: :environment do
    source = spotify_source
    account = Spotify::Account.new
    me = account.with_token(source) { |token| account.client.me(token) }
    puts "Account: #{me['display_name'] || me['id']} (#{me['id'] == source.external_account_id ? 'matches the stored account' : 'DIFFERENT from the stored account'})"
    puts "Granted scopes: #{source.reload.scopes}"
    items = spotify_pages(account, source, pages: ENV.fetch("PAGES", "5").to_i)
    events = items.filter_map { |item| Spotify::Mapping.event(item) rescue nil }
    times = events.map(&:reported_at).sort
    puts "Retrievable: #{items.size} plays, #{events.size} readable, #{events.map(&:source_event_id).uniq.size} distinct"
    puts "Oldest #{times.first&.iso8601(3)}, newest #{times.last&.iso8601(3)}" if times.any?
    puts "Requests: #{account.client.requests}"
  end

  desc "Read-only: what ingestion would do with the recent plays, against the archive; LASTFM=1 also measures timestamps against Last.fm"
  task compare: :environment do
    source = spotify_source
    account = Spotify::Account.new
    events = spotify_pages(account, source, pages: 1).filter_map { |item| Spotify::Mapping.event(item) rescue nil }.sort_by(&:reported_at)
    abort "spotify: no recent plays" if events.empty?

    matcher = Listening::CrossSource.new(user_id: source.user_id, provider: "spotify")
    seen = ListeningObservation.where(listening_source_id: source.id, source_event_id: events.map(&:source_event_id)).pluck(:source_event_id).to_set
    decisions = events.map do |e|
      next [ e, :already_stored, nil ] if seen.include?(e.source_event_id)

      fields = { artist_name: e.artist_name, track_name: e.track_name, album_name: e.album_name.to_s }
      variant = NameVariant.find_by(variant_hash: NameVariant.hash_for(fields)) || NameVariant.new(fields)
      d = matcher.decide(e, variant)
      [ e, d.action, d.evidence ]
    end
    puts "#{events.size} recent plays, #{events.first.reported_at.iso8601} to #{events.last.reported_at.iso8601}"
    puts "Would: #{decisions.map { |_, a, _| a }.tally.inspect} (create = new play, link = already in the archive, review = held for a person)"
    puts "Archive plays in that span: #{Scrobble.present.where(user_id: source.user_id, played_at: (events.first.reported_at - 1.hour)..events.last.reported_at).count}"

    if ENV["LASTFM"] == "1"
      identity = source.user.lastfm_identity or abort "spotify: no Last.fm identity"
      page = Lastfm::Config.client.recent_tracks(username: identity.username, session_key: identity.session_key, limit: 200,
                                                 from: events.first.reported_at - 1.hour, to: events.last.reported_at + 1.hour)
      lastfm = page.scrobbles.select(&:played_at)
      norm = ->(a, t) { [ CatalogName.normalize(a), CatalogName.normalize(t) ] }
      used = Set.new
      offsets = events.filter_map do |e|
        match = lastfm.each_with_index.select { |s, i| !used.include?(i) && norm.(s.artist, s.track) == norm.(e.artist_name, e.track_name) && s.played_at <= e.reported_at + 60 }
                      .min_by { |s, _| (e.reported_at - s.played_at).abs }
        next unless match

        used << match.last
        gap = e.reported_at - match.first.played_at
        [ gap.round(1), (e.duration_ms.to_i / 1000.0).round(1) ]
      end
      puts "Last.fm (read-only, nothing stored): #{lastfm.size} plays in the span; #{offsets.size} of #{events.size} Spotify plays found there"
      if offsets.any?
        diffs = offsets.map { |gap, dur| (gap - dur).round(1) }.sort
        puts "Spotify played_at minus Last.fm start, minus the track's duration (0 = played_at is the end of a full play):"
        puts "  min #{diffs.first}s, median #{diffs[diffs.size / 2]}s, max #{diffs.last}s"
        puts "  raw gaps (seconds, duration): #{offsets.first(15).inspect}"
      end
    end
  end

  desc "Poll the connected account once, now, in this process (needs SPOTIFY_INGESTION_ENABLED for this command)"
  task poll: :environment do
    abort "spotify: SPOTIFY_INGESTION_ENABLED is off; set it for this command only" unless ListeningStorage.enabled?("spotify")

    source = spotify_source
    result = Spotify::Poller.new.poll!(source, trigger: "task", force: ENV["FORCE"] == "1")
    poll = result.poll
    puts "Status: #{result.status}"
    if poll
      puts "Fetched #{poll.items} plays in #{poll.pages} page(s) (#{poll.http_requests} requests); recorded: #{poll.recorded.inspect}"
      puts "Span: #{poll.oldest_reported_at&.iso8601(3)} to #{poll.newest_reported_at&.iso8601(3)}; reached plays recorded before: #{poll.reached_known}"
      puts "Error: #{poll.error}" if poll.error
    end
    gaps = source.gaps.open.order(:gap_from)
    puts "Possible gaps: #{gaps.map { |g| "#{g.gap_from.iso8601} to #{g.gap_to.iso8601}" }.join(', ').presence || 'none'}"
  end
end
