module Metadata
  # Artwork for albums and tracks that have no catalogue release id, from ListenBrainz's own MBID
  # mapping of a user's listens (docs/milestone-4-plan.md §14). The mapping stays ListenBrainz's
  # opinion: nothing here touches name variants, albums, tracks or reviews. A user sees a cover on
  # one Overview key when every one of their own observations for it maps to the same release, and
  # MusicBrainz's record of that release credits the same artist (and, for an album, carries the
  # same title). The cover is fetched like any other (CoverArt::Client: same pacing, approved hosts,
  # negative result, backoff) and kept in metadata_artworks under the release id; the inference
  # itself lives in inferred_artworks, per user, and is withdrawn when later listens disagree.
  module InferredArtwork
    PROVIDER = "listenbrainz_mapping".freeze
    MAX_ATTEMPTS = 5
    FAILED_RETRY = 7.days

    Plan = Data.define(:candidates, :conflicts, :queued, :withdrawn)
    Summary = Data.define(:processed, :found, :none, :mismatch, :retrying, :failed, :requests)

    # The user's ListenBrainz observations that carry a release mapping, with the Overview keys of
    # their variants (Analytics::Identity, the same keys the Overview groups by).
    CANDIDATES_SQL = <<~SQL.freeze
      WITH #{Analytics::Identity.ctes("SELECT DISTINCT name_variant_id FROM listening_observations WHERE user_id = :user AND provider = 'listenbrainz' AND context->'mbid_mapping'->>'release_mbid' IS NOT NULL")}
      SELECT k.album_key, k.track_key, k.artist_name, k.album_name, k.track_name,
             o.context->'mbid_mapping'->>'release_mbid', o.context->'mbid_mapping'->>'recording_mbid', count(*)
        FROM keyed k JOIN listening_observations o ON o.name_variant_id = k.id
       WHERE o.user_id = :user AND o.provider = 'listenbrainz' AND o.context->'mbid_mapping'->>'release_mbid' IS NOT NULL
       GROUP BY 1, 2, 3, 4, 5, 6, 7
    SQL

    module_function

    # Rewrites the user's candidates from their observations: one row per album key (or, for a
    # track with no album, per track key) whose observations all map to one release. A changed
    # release is checked again; a key whose evidence now conflicts, or has gone, loses its row.
    def plan!(user, now: Time.current)
      Enrichment.ensure_enabled!
      groups = Hash.new { |h, k| h[k] = { releases: Hash.new(0), recordings: Hash.new(0), names: nil } }
      ActiveRecord::Base.connection.select_rows(ActiveRecord::Base.sanitize_sql_array([ CANDIDATES_SQL, { user: user.id } ])).each do |album_key, track_key, artist, album, track, release, recording, n|
        next unless release.to_s.match?(Catalogue::Matcher::MBID)

        g = groups[album_key || track_key]
        g[:releases][release] += n.to_i
        g[:recordings][recording] += n.to_i if recording.to_s.match?(Catalogue::Matcher::MBID)
        g[:names] ||= { "subject" => album_key ? "album" : "track", "artist" => artist, "album" => album, "track" => track }
      end
      conflicts = queued = 0
      kept = []
      groups.each do |key, g|
        if g[:releases].size != 1
          conflicts += 1
          next
        end
        release = g[:releases].keys.first
        row = ::InferredArtwork.find_or_initialize_by(user: user, subject_key: key)
        changed = row.new_record? || row.release_id != release
        row.assign_attributes(provider: PROVIDER, release_id: release, observations: g[:releases][release],
                              recording_id: g[:recordings].size == 1 ? g[:recordings].keys.first : nil,
                              evidence: (changed ? {} : row.evidence).merge(g[:names]))
        if changed
          row.assign_attributes(status: "pending", attempts: 0, next_attempt_at: nil, checked_at: nil, last_error: nil)
          queued += 1
        end
        row.save!
        kept << key
      end
      withdrawn = ::InferredArtwork.where(user: user).where.not(subject_key: kept).delete_all
      Plan.new(candidates: groups.size - conflicts, conflicts: conflicts, queued: queued, withdrawn: withdrawn)
    end

    def same?(a, b) = CatalogName.normalize(a).present? && CatalogName.normalize(a) == CatalogName.normalize(b)

    class Enricher
      def initialize(cover_art: CoverArt::Client.new, musicbrainz: MusicBrainz::Client.new, clock: -> { Time.current })
        @cover_art = cover_art
        @musicbrainz = musicbrainz
        @clock = clock
      end

      def run!(limit: 25)
        Enrichment.ensure_enabled!
        counts = Hash.new(0)
        ::InferredArtwork.due(now).limit(limit).to_a.each { |row| counts[process(row)] += 1 }
        Summary.new(processed: counts.values.sum, found: counts[:found], none: counts[:none], mismatch: counts[:mismatch],
                    retrying: counts[:retrying], failed: counts[:failed], requests: @cover_art.requests.to_i + @musicbrainz.requests.to_i)
      end

      private

      def now = @clock.call

      # MusicBrainz's record of the release decides whether the mapping is compatible with what the
      # user played; only then is the cover looked up, and only if no row for that release exists.
      def process(row)
        response = @musicbrainz.release(row.release_id)
        return settle!(row, "none", "musicbrainz" => "release #{response.status}") unless response.status == 200

        body = response.body
        credit = Array(body["artist-credit"]).map { |c| "#{c["name"]}#{c["joinphrase"]}" }.join
        evidence = { "release_title" => body["title"], "artist_credit" => credit }
        compatible = Metadata::InferredArtwork.same?(credit, row.evidence["artist"]) &&
                     (row.evidence["subject"] != "album" || Metadata::InferredArtwork.same?(body["title"], row.evidence["album"]))
        return settle!(row, "mismatch", evidence) unless compatible

        art = MetadataArtwork.find_by(provider: Artwork::PROVIDER, release_id: row.release_id) || fetch!(row.release_id, body.dig("release-group", "id"))
        settle!(row, art.found_on ? "ok" : "none", evidence.merge("found_on" => art.found_on))
      rescue MusicBrainz::Client::RateLimited, MusicBrainz::Client::Unavailable, Lastfm::Error::RateLimited => e
        retry_later(row, e)
      end

      # The release's own front cover, else its release group's: the same reference as Metadata::Artwork keeps.
      def fetch!(release, group)
        cover = @cover_art.front("release", release)
        found_on = cover && "release"
        if cover.nil? && group
          cover = @cover_art.front("release-group", group)
          found_on = cover && "release_group"
        end
        ActiveRecord::Base.transaction do
          art = MetadataArtwork.create!(provider: Artwork::PROVIDER, release_id: release, release_group_id: group, found_on: found_on,
                                        image_id: cover&.image_id, thumbnail_250: cover&.thumbnail_250, thumbnail_500: cover&.thumbnail_500,
                                        thumbnail_1200: cover&.thumbnail_1200, source_url: cover&.source_url || "#{CoverArt::Client::BASE}/release/#{release}",
                                        fetched_at: now)
          MetadataFetch.create!(provider: Artwork::PROVIDER, entity_kind: "release", provider_id: release, url: art.source_url, http_status: 200,
                                outcome: found_on ? "ok" : "not_found", requested_at: now, changed_values: { found_on: found_on, release_group_id: group, via: PROVIDER }.compact)
          art
        end
      end

      def settle!(row, status, evidence)
        row.update!(status: status, attempts: 0, next_attempt_at: nil, checked_at: now, last_error: nil, evidence: row.evidence.merge(evidence))
        { "ok" => :found, "none" => :none, "mismatch" => :mismatch }.fetch(status)
      end

      def retry_later(row, error)
        attempts = row.attempts + 1
        gave_up = attempts >= MAX_ATTEMPTS
        wait = gave_up ? FAILED_RETRY : [ 60 * (4**(attempts - 1)), 1.day.to_i ].min.seconds
        row.update!(status: gave_up ? "failed" : "pending", attempts: gave_up ? 0 : attempts, next_attempt_at: now + wait, last_error: error.message.truncate(300))
        gave_up ? :failed : :retrying
      end
    end
  end
end
