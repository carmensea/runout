module Metadata
  # Album artwork from the Cover Art Archive (docs/milestone-4-plan.md §10.4), queued and fetched like
  # artist metadata (Metadata::Planner, Metadata::Enricher): most played releases first, references
  # and provenance only, negative results cached, bounded retries. Albums without a release ID are
  # never queued: nothing is matched by name.
  module Artwork
    PROVIDER = "coverartarchive".freeze
    REFRESH = 2.years   # a found cover is asked about again only this often: front covers rarely change
    NEGATIVE = 180.days # a missing one is asked about again sooner: covers get uploaded
    FAILED_RETRY = 7.days
    MAX_ATTEMPTS = 5

    PLAYED_SQL = <<~SQL.freeze
      SELECT r.mbid, count(*) AS plays
        FROM scrobbles s
        JOIN name_variants v ON v.id = s.name_variant_id
        LEFT JOIN #{Catalogue::Roots.sql('albums')} root ON root.id = v.album_id
        JOIN albums r ON r.id = COALESCE(root.root_id, v.album_id)
       WHERE s.removed_at IS NULL AND r.mbid IS NOT NULL
       GROUP BY r.mbid
       ORDER BY plays DESC, r.mbid
    SQL

    Summary = Data.define(:processed, :found, :none, :retrying, :failed, :requests)

    module_function

    def played_releases = ActiveRecord::Base.connection.select_rows(PLAYED_SQL)

    def plan!(limit: nil, now: Time.current)
      Enrichment.ensure_enabled!
      list = played_releases
      list = list.first(limit) if limit
      rows = list.map do |mbid, plays|
        { provider: PROVIDER, entity_kind: "release", provider_id: mbid, priority: plays, status: "pending",
          next_attempt_at: now, created_at: now, updated_at: now }
      end
      rows.each_slice(1000) { |batch| MetadataTarget.upsert_all(batch, unique_by: :index_metadata_targets_identity, update_only: %i[priority]) }
      MetadataTarget.where(provider: PROVIDER).count
    end

    class Enricher
      def initialize(cover_art: CoverArt::Client.new, musicbrainz: MusicBrainz::Client.new, clock: -> { Time.current })
        @cover_art = cover_art
        @musicbrainz = musicbrainz
        @clock = clock
      end

      def run!(limit: 50)
        Enrichment.ensure_enabled!
        counts = Hash.new(0)
        MetadataTarget.due(now).where(provider: PROVIDER, entity_kind: "release").limit(limit).to_a.each { |t| counts[process(t)] += 1 }
        Summary.new(processed: counts.values.sum, found: counts[:found], none: counts[:none], retrying: counts[:retrying],
                    failed: counts[:failed], requests: @cover_art.requests.to_i + @musicbrainz.requests.to_i)
      end

      private

      def now = @clock.call

      # The release's own front cover; otherwise its release group's, through MusicBrainz's link.
      def process(target)
        release = target.provider_id
        cover = @cover_art.front("release", release)
        found_on = cover && "release"
        group = nil
        unless cover
          response = @musicbrainz.release(release)
          group = response.body&.dig("release-group", "id") if response.status == 200
          cover = group && @cover_art.front("release-group", group)
          found_on = cover && "release_group"
        end
        store(target, release, group, found_on, cover)
      rescue MusicBrainz::Client::RateLimited, MusicBrainz::Client::Unavailable, Lastfm::Error::RateLimited => e
        retry_later(target, e)
      end

      def store(target, release, group, found_on, cover)
        ActiveRecord::Base.transaction do
          art = MetadataArtwork.find_or_initialize_by(provider: PROVIDER, release_id: release)
          art.update!(release_group_id: group, found_on: found_on, image_id: cover&.image_id, thumbnail_250: cover&.thumbnail_250,
                      thumbnail_500: cover&.thumbnail_500, thumbnail_1200: cover&.thumbnail_1200,
                      source_url: cover&.source_url || "#{CoverArt::Client::BASE}/release/#{release}", fetched_at: now)
          MetadataFetch.create!(provider: PROVIDER, entity_kind: "release", provider_id: release, url: art.source_url,
                                http_status: 200, outcome: found_on ? "ok" : "not_found", requested_at: now,
                                changed_values: { found_on: found_on, release_group_id: group }.compact)
          target.update!(status: found_on ? "ok" : "not_found", attempts: 0, last_attempt_at: now, last_success_at: now, last_error: nil,
                         next_attempt_at: now + (found_on ? REFRESH : NEGATIVE))
        end
        found_on ? :found : :none
      end

      def retry_later(target, error)
        attempts = target.attempts + 1
        gave_up = attempts >= MAX_ATTEMPTS
        wait = gave_up ? FAILED_RETRY : [ 60 * (4**(attempts - 1)), 1.day.to_i ].min.seconds
        ActiveRecord::Base.transaction do
          MetadataFetch.create!(provider: PROVIDER, entity_kind: "release", provider_id: target.provider_id,
                                url: "#{CoverArt::Client::BASE}/release/#{target.provider_id}",
                                outcome: error.is_a?(MusicBrainz::Client::Unavailable) ? "error" : "rate_limited",
                                error: error.message.truncate(300), requested_at: now)
          target.update!(status: gave_up ? "failed" : target.status, attempts: gave_up ? 0 : attempts, last_attempt_at: now,
                         last_error: error.message.truncate(300), next_attempt_at: now + wait)
        end
        gave_up ? :failed : :retrying
      end
    end
  end
end
