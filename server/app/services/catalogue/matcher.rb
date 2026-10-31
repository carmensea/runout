module Catalogue
  # Links name variants to canonical artists, albums (releases) and tracks (recordings)
  # (docs/milestone-2-plan.md §6.4). Runs offline from the stored strings: no MusicBrainz or
  # Last.fm requests, and independent of importing. Only the links and match state on
  # `name_variants` change; the strings and every scrobble stay as they are.
  #
  # Rules, per level (artist first; albums and tracks are scoped to the resolved artist):
  # 1. A valid MusicBrainz ID links to the entity with that ID, created if needed (`mbid`). Last.fm's
  #    track MBID identifies a recording and its album MBID a release, so remasters, live versions
  #    and remixes with their own IDs stay apart.
  # 2. Artists only: a curated alias naming exactly one artist links to it (`alias`).
  # 3. Otherwise the variant joins the name-only entity (no MBID) with that normalised name,
  #    created if needed (`name`). It never joins an identified entity on name alone: if one with
  #    the same name exists, a `possible_match` review is opened instead. Exception, artists only:
  #    exactly one identified artist with the name and nothing contradicting it links to that
  #    artist (`inferred`, Catalogue::ArtistInference).
  # 4. Several name-only entities with that name (after a person split them): `ambiguous`, linked
  #    to none, with a review listing the candidates.
  # 5. No usable name, or no resolved artist for an album or track: `unmatched`. No album: `none`.
  #
  # An ID Last.fm reported inconsistently for these exact strings (MbidDispute) isn't used: rule 1 is
  # skipped at that level, so every play of the song falls back to the same name rule, whatever ID
  # it was stored with, and one song doesn't become two tracks. The variant keeps its ID.
  #
  # Manual decisions (Catalogue::Decisions) are never overridden. Entities merged by a decision
  # are followed to the entity they were merged into. Re-running is idempotent: candidates are
  # found before anything is created, under a lock per name, so no duplicates appear.
  class Matcher
    VERSION = 1
    MODELS = { "artist" => Artist, "album" => Album, "track" => Track }.freeze
    LINK_COLUMNS = { "artist" => :artist_id, "album" => :album_id, "track" => :track_id }.freeze
    MBID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
    LEVELS = %i[artist album track].freeze

    Result = Data.define(:record, :status, :reviews) do
      def self.linked(record, status, reviews = []) = new(record: record, status: status, reviews: reviews)
      def self.unlinked(status, reviews = []) = new(record: nil, status: status, reviews: reviews)
    end

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    # Matches every variant not yet matched under the current rules. Returns how many were processed.
    # `limit` bounds one call, so a job never runs for long.
    def match_pending!(limit: nil)
      scope = NameVariant.where("match_version IS NULL OR match_version < ?", VERSION).order(:id)
      count = 0
      scope.in_batches(of: 500) do |batch|
        batch.order(:id).each do |variant|
          return count if limit && count >= limit

          match!(variant)
          count += 1
        end
      end
      count
    end

    # Matches the variants in one user's history. Other users' variants aren't touched.
    def match_user!(user)
      NameVariant.where(id: Scrobble.where(user_id: user.id).select(:name_variant_id)).find_each.count { |variant| match!(variant) }
    end

    def match!(variant)
      ListeningStorage.ensure_writable!
      NameVariant.transaction do
        v = NameVariant.lock.find(variant.id)
        @disputed = MbidDispute.levels_for(v)
        artist = v.artist_match == "manual" ? Result.linked(v.artist.resolved, "manual") : resolve_artist(v)
        album = v.album_match == "manual" ? Result.linked(v.album.resolved, "manual") : resolve_album(v, artist.record)
        track = v.track_match == "manual" ? Result.linked(v.track.resolved, "manual") : resolve_track(v, artist.record)
        apply(v, artist: artist, album: album, track: track)
      end
      true
    end

    # The artist and every artist merged into it, directly or through others.
    def family_ids(artist)
      ids = [ artist.id ]
      frontier = ids
      while (frontier = Artist.where(merged_into_id: frontier).where.not(id: ids).pluck(:id)).any?
        ids += frontier
      end
      ids
    end

    private

    def now = @clock.call

    def resolve_artist(v)
      if (mbid = usable_mbid(v, "artist"))
        return by_mbid(Artist, mbid) { Artist.new(name: v.artist_name, mbid: mbid) }
      end

      norm = CatalogName.normalize(v.artist_name)
      return Result.unlinked("unmatched") if norm.empty?

      aliased = ArtistAlias.where(normalized_name: norm).includes(:artist).map { |a| a.artist.resolved }.uniq.sort_by(&:id)
      return Result.linked(aliased.sole, "alias") if aliased.size == 1
      return Result.unlinked("ambiguous", [ [ "ambiguous", aliased.map(&:id) ] ]) if aliased.size > 1

      lock!("artist:#{norm}")
      if (inferred = ArtistInference.new(clock: @clock).infer_variant(v, norm))
        return Result.linked(inferred, "inferred")
      end

      by_name(Artist.where(normalized_name: norm), lock_key: "artist:#{norm}") { Artist.new(name: v.artist_name) }
    end

    def resolve_album(v, artist)
      mbid = usable_mbid(v, "album")
      norm = CatalogName.normalize(v.album_name)
      return Result.unlinked("none") if mbid.nil? && norm.empty?

      resolve_scoped(Album, :normalized_title, mbid: mbid, norm: norm, artist: artist) { Album.new(artist: artist, title: v.album_name, mbid: mbid) }
    end

    def resolve_track(v, artist)
      mbid = usable_mbid(v, "track")
      norm = CatalogName.normalize(v.track_name)
      resolve_scoped(Track, :normalized_title, mbid: mbid, norm: norm, artist: artist) { Track.new(artist: artist, title: v.track_name, mbid: mbid) }
    end

    # Albums and tracks: by MBID wherever it is (creating needs an artist and a title), otherwise
    # by title within the resolved artist and any artists merged into it.
    def resolve_scoped(model, column, mbid:, norm:, artist:, &build)
      if mbid
        existing = model.find_by(mbid: mbid)
        return Result.linked(existing.resolved, "mbid") if existing
        return Result.unlinked("unmatched") unless artist && norm.present?

        return by_mbid(model, mbid, &build)
      end
      return Result.unlinked("unmatched") unless artist && norm.present?

      by_name(model.where(artist_id: family_ids(artist), column => norm), lock_key: "#{model.name}:#{artist.id}:#{norm}") do
        build.call.tap { |record| record.mbid = nil }
      end
    end

    def by_mbid(model, mbid)
      record = model.find_by(mbid: mbid)
      record ||= begin
        model.transaction(requires_new: true) { yield.tap(&:save!) }
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
        model.find_by(mbid: mbid) || raise
      end
      Result.linked(record.resolved, "mbid")
    end

    def by_name(scope, lock_key:)
      lock!(lock_key)
      same_name = scope.order(:id).to_a
      name_only = same_name.select { |r| r.mbid.nil? }
      identified = same_name.select { |r| r.mbid && r.merged_into_id.nil? }
      targets = name_only.map(&:resolved).uniq

      return Result.unlinked("ambiguous", [ [ "ambiguous", targets.map(&:id).sort ] ]) if targets.size > 1

      record = targets.first || yield.tap(&:save!)
      status = followed_merge_status(name_only.select(&:merged_into_id))
      reviews = record.mbid.nil? && identified.any? ? [ [ "possible_match", identified.map(&:id).sort ] ] : []
      Result.linked(record, status, reviews)
    end

    def apply(v, **results)
      results.each do |level, result|
        v.public_send(:"#{level}_id=", result.record&.id)
        v.public_send(:"#{level}_match=", result.status)
      end
      v.matched_at = now if v.changed?
      v.match_version = VERSION
      v.save! if v.changed?
      results.each { |level, result| sync_reviews(v, level.to_s, result) unless result.status == "manual" }
    end

    # Opens the reviews this match calls for, keeps identical open ones, and supersedes the rest.
    # A review a person dismissed isn't reopened for the same candidates.
    def sync_reviews(v, level, result)
      wanted = result.reviews.to_h
      v.catalogue_reviews.open.where(level: level).find_each do |review|
        review.update!(state: "superseded") unless wanted[review.kind] == review.candidate_ids.sort
      end
      wanted.each do |kind, ids|
        existing = v.catalogue_reviews.where(level: level, kind: kind, state: %w[open dismissed])
        next if existing.any? { |review| review.candidate_ids.sort == ids }

        v.catalogue_reviews.create!(level: level, kind: kind, candidate_ids: ids)
      end
    end

    # `name` when no merge was followed. A merge made by an inference (Catalogue::ArtistInference)
    # is `inferred` for artists and `name` for albums and tracks, joined as the name rule would;
    # a person's merge is `manual`.
    def followed_merge_status(merged)
      return "name" if merged.empty?
      return "manual" unless merged.all?(&:inference_id)

      merged.first.is_a?(Artist) ? "inferred" : "name"
    end

    def usable_mbid(v, level)
      @disputed.include?(level) ? nil : valid_mbid(v.public_send(:"#{level}_mbid"))
    end

    def valid_mbid(value)
      value = value.to_s.strip.downcase
      value.match?(MBID) ? value : nil
    end

    def lock!(key)
      NameVariant.connection.execute(NameVariant.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "catalogue:#{key}" ]))
    end
  end
end
