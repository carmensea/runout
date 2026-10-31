module Metadata
  # Works through due enrichment targets, most played first (docs/milestone-4-plan.md §5).
  #
  # - Found: the artist and its genres and tags are stored as fetched, with provider, licence,
  #   source URL and time; the changes since the last fetch go into the refresh history; refreshed
  #   again after REFRESH.
  # - Not found (404) or invalid (400): cached as a negative result, asked again after NEGATIVE.
  # - Rate limited or unavailable: retried with backoff, at most MAX_ATTEMPTS times in a row, then
  #   `failed` until FAILED_RETRY.
  # - The entity's genre classification is rebuilt after each fetch.
  # Network requests happen outside database transactions. Interrupted runs resume where they were.
  class Enricher
    REFRESH = 180.days
    NEGATIVE = 180.days
    FAILED_RETRY = 7.days
    MAX_ATTEMPTS = 5

    Summary = Data.define(:processed, :ok, :not_found, :invalid, :retrying, :failed, :requests)

    def initialize(client: MusicBrainz::Client.new, clock: -> { Time.current })
      @client = client
      @clock = clock
    end

    def run!(limit: 50)
      Enrichment.ensure_enabled!
      counts = Hash.new(0)
      MetadataTarget.due(now).where(provider: Enrichment::PROVIDER, entity_kind: "artist").limit(limit).to_a.each do |target|
        counts[process(target)] += 1
      end
      Summary.new(processed: counts.values.sum, ok: counts[:ok], not_found: counts[:not_found], invalid: counts[:invalid],
                  retrying: counts[:retrying], failed: counts[:failed], requests: @client.requests.to_i)
    end

    private

    def now = @clock.call

    def process(target)
      response = @client.artist(target.provider_id)
      case response.status
      when 200 then found(target, response)
      when 404 then negative(target, response, "not_found", NEGATIVE)
      else negative(target, response, "invalid", NEGATIVE)
      end
    rescue MusicBrainz::Client::RateLimited, MusicBrainz::Client::Unavailable, Lastfm::Error::RateLimited => e
      retry_later(target, e)
    end

    def found(target, response)
      body = response.body
      ActiveRecord::Base.transaction do
        artist = MetadataArtist.find_or_initialize_by(provider: Enrichment::PROVIDER, provider_id: target.provider_id)
        before = artist.attributes.slice(*FIELDS)
        artist.assign_attributes(
          canonical_id: body["id"] == target.provider_id ? nil : body["id"],
          name: body["name"], sort_name: body["sort-name"], disambiguation: body["disambiguation"].presence,
          artist_type: body["type"], gender: body["gender"],
          area_name: body.dig("area", "name"), area_code: Array(body.dig("area", "iso-3166-1-codes")).first,
          begin_date: body.dig("life-span", "begin"), end_date: body.dig("life-span", "end"), ended: body.dig("life-span", "ended"),
          core_license: Enrichment::CORE_LICENSE, source_url: response.url, fetched_at: now
        )
        changed = artist.changed & FIELDS
        artist.save!
        tag_changes = replace_tags(target.provider_id, body)
        log(target, response, "ok", changes: { fields: changed.to_h { |f| [ f, [ before[f], artist[f] ] ] }.compact_blank, **tag_changes }.compact_blank)
        target.update!(status: "ok", attempts: 0, last_attempt_at: now, last_success_at: now, last_http_status: 200, last_error: nil,
                       next_attempt_at: now + REFRESH)
      end
      Genres::Classifications.recompute!([ target.provider_id ])
      :ok
    end

    FIELDS = %w[canonical_id name sort_name disambiguation artist_type gender area_name area_code begin_date end_date ended].freeze

    # Genres and tags as fetched, replacing the previous set; returns what was added and removed.
    def replace_tags(mbid, body)
      fetched = [ [ "genre", body["genres"] ], [ "tag", body["tags"] ] ].flat_map do |kind, list|
        Array(list).map { |t| [ kind, t["name"].to_s, t["count"].to_i ] }
      end
      scope = MetadataTag.where(provider: Enrichment::PROVIDER, entity_kind: "artist", provider_id: mbid)
      before = scope.pluck(:kind, :name, :votes)
      scope.delete_all
      if fetched.any?
        MetadataTag.insert_all!(fetched.map do |kind, name, votes|
          { provider: Enrichment::PROVIDER, entity_kind: "artist", provider_id: mbid, kind: kind, name: name, votes: votes,
            license: Enrichment::SUPPLEMENTARY_LICENSE, fetched_at: now, created_at: now, updated_at: now }
        end)
      end
      { added: (fetched - before).map { |k, n, v| "#{k}:#{n}:#{v}" }, removed: (before - fetched).map { |k, n, v| "#{k}:#{n}:#{v}" } }
    end

    def negative(target, response, status, wait)
      ActiveRecord::Base.transaction do
        log(target, response, status)
        target.update!(status: status, attempts: 0, last_attempt_at: now, last_http_status: response.status, last_error: nil,
                       next_attempt_at: now + wait)
      end
      status.to_sym
    end

    def retry_later(target, error)
      attempts = target.attempts + 1
      gave_up = attempts >= MAX_ATTEMPTS
      wait = gave_up ? FAILED_RETRY : [ 60 * (4**(attempts - 1)), 1.day.to_i ].min.seconds
      wait = [ wait, error.retry_after.to_f.seconds ].max if error.respond_to?(:retry_after) && error.retry_after
      ActiveRecord::Base.transaction do
        MetadataFetch.create!(provider: Enrichment::PROVIDER, entity_kind: "artist", provider_id: target.provider_id,
                              url: "#{MusicBrainz::Client::BASE}/artist/#{target.provider_id}", outcome: error.is_a?(MusicBrainz::Client::Unavailable) ? "error" : "rate_limited",
                              error: error.message.truncate(300), requested_at: now)
        target.update!(status: gave_up ? "failed" : target.status, attempts: gave_up ? 0 : attempts, last_attempt_at: now,
                       last_error: error.message.truncate(300), next_attempt_at: now + wait)
      end
      gave_up ? :failed : :retrying
    end

    def log(target, response, outcome, changes: {})
      MetadataFetch.create!(provider: Enrichment::PROVIDER, entity_kind: "artist", provider_id: target.provider_id, url: response.url,
                            http_status: response.status, outcome: outcome, duration_ms: response.duration_ms, changed_values: changes,
                            requested_at: now)
    end
  end
end
