module Catalogue
  # Joins an artist name without a MusicBrainz ID to the one identified artist with that name, when
  # nothing contradicts it. Last.fm sends the artist ID with some plays and not others, so under the
  # name rule alone (Matcher rule 3) one artist became two: the identified one and a name-only twin.
  #
  # A name-only artist (or a new variant of the name) joins identified artist A only if:
  # - after following merges, exactly one identified artist has the name, and A is it;
  # - there is no other name-only artist with the name (a person may have split them), nothing was
  #   merged into it or from it by a person, and no curated alias names it;
  # - no play of it was linked by hand, no possible-match review with A was dismissed, and the same
  #   inference wasn't reverted before;
  # - no recording or release among its plays (linked by MusicBrainz ID) belongs to another
  #   identified artist, and its artist ID isn't disputed (MbidDispute).
  #
  # Existing twins are merged (merged_into, marked with the inference), so every play, track and
  # album follows the merge chain to A. Their name-only albums and tracks join A's name-only ones of
  # the same title, as the name rule would have had them. Nothing with a MusicBrainz ID is merged,
  # and no scrobble or variant string changes. Each inference is recorded with its evidence
  # (CatalogueInference); the possible-match reviews it settles are resolved and point at it.
  # `revert!` undoes one, and it is never made again.
  class ArtistInference
    RULE_VERSION = 1

    Candidate = Data.define(:normalized_name, :from, :into, :variant_ids, :plays, :excluded, :albums, :tracks) do
      def eligible? = excluded.nil?
    end

    def initialize(clock: -> { Time.current })
      @clock = clock
    end

    # Every name-only artist sharing its normalised name with an identified artist, with the artist it
    # would join, or why it won't. Merged twins already joined by an inference aren't listed. Reads only.
    def candidates
      names = Artist.group(:normalized_name)
                    .having("count(*) FILTER (WHERE mbid IS NULL) > 0 AND count(*) FILTER (WHERE mbid IS NOT NULL) > 0")
                    .pluck(:normalized_name)
      names.sort.flat_map { |name| candidates_for(name) }
    end

    # Applies the eligible candidates, then re-matches the plays they affect. Returns the inferences.
    def apply!(candidates = self.candidates)
      HistoryImport.ensure_enabled!
      inferences = candidates.select(&:eligible?).filter_map { |c| apply_one!(c) }
      Matcher.new(clock: @clock).match_pending!
      inferences
    end

    # For Matcher: a new variant without a usable artist ID, whose name has no name-only artist yet.
    # The identified artist it joins, or nil. Records the inference the first time it is used.
    def infer_variant(variant, normalized_name)
      same = Artist.where(normalized_name: normalized_name).to_a
      return if same.empty? || same.any? { |a| a.mbid.nil? }

      targets = same.map(&:resolved).uniq
      into = targets.sole if targets.size == 1
      return unless into&.mbid
      return if blocked?(normalized_name, into) || disputed?([ variant ]) || conflicting?([ variant ], into)
      return if dismissed?([ variant.id ], same.map(&:id))

      record_inference!(normalized_name, into, nil, { "variant_id" => variant.id })
      into
    end

    # Undoes an inference: its merges are cleared (unless a person has changed them since), its plays
    # are matched again, and the same inference is never made again. Resolved reviews stay as they
    # were; matching opens new ones where they still apply.
    def revert!(inference)
      HistoryImport.ensure_enabled!
      variant_ids = nil
      Artist.transaction do
        lock_merges!
        [ Artist, Album, Track ].each do |model|
          model.where(inference_id: inference.id).find_each { |e| e.update!(merged_into: nil, inference_id: nil) }
        end
        inference.update!(state: "reverted", reverted_at: now)
        artist_ids = [ inference.into_id, inference.from_id ].compact
        variant_ids = NameVariant.where(artist_id: artist_ids).select(:id, :artist_name).to_a
                                 .select { |v| CatalogName.normalize(v.artist_name) == inference.normalized_name }.map(&:id)
        variant_ids += NameVariant.where(artist_id: inference.from_id).pluck(:id) if inference.from_id
        NameVariant.where(id: variant_ids).update_all(match_version: nil)
      end
      Matcher.new(clock: @clock).match_pending!
      inference.reload
    end

    private

    def now = @clock.call

    def candidates_for(name)
      same = Artist.where(normalized_name: name).order(:id).to_a
      name_only = same.select { |a| a.mbid.nil? }
      targets = same.select(&:mbid).map(&:resolved).uniq
      unmerged_name_only = name_only.reject(&:merged_into_id)

      name_only.filter_map do |artist|
        next if artist.inference_id # joined by an inference already

        variants = NameVariant.where(artist_id: artist.id).to_a
        into = targets.sole if targets.size == 1
        reason = exclusion(name, artist, into, targets, unmerged_name_only, variants, same)
        albums, tracks = reason ? [ [], [] ] : title_merges(artist, into)
        Candidate.new(normalized_name: name, from: artist, into: into, variant_ids: variants.map(&:id),
                      plays: Scrobble.where(name_variant_id: variants.map(&:id)).count, excluded: reason, albums: albums, tracks: tracks)
      end
    end

    def exclusion(name, artist, into, targets, unmerged_name_only, variants, same)
      return "merged by a person" if artist.merged_into_id
      return "several identified artists have this name" if targets.size > 1
      return "the identified artist was merged into a name-only one" unless into&.mbid
      return "several name-only artists have this name" if unmerged_name_only.size > 1
      return "other artists were merged into it" if artist.merged_from.exists?
      return "a curated alias names it" if ArtistAlias.exists?(normalized_name: name)
      return "a person linked its plays by hand" if variants.any? { |v| v.artist_match == "manual" }
      return "a person dismissed the match" if dismissed?(variants.map(&:id), same.select(&:mbid).map(&:id))
      return "this inference was reverted before" if blocked?(name, into)
      return "its artist ID is disputed" if disputed?(variants)
      return "a recording or release among its plays belongs to another artist" if conflicting?(variants, into)

      nil
    end

    # Name-only albums and tracks of `from` with exactly one name-only twin of the same title under
    # `into` (or artists merged into it): [[from id, into id], ...] for albums and for tracks.
    def title_merges(from, into)
      family = Matcher.new.family_ids(into) - [ from.id ]
      [ Album, Track ].map do |model|
        model.where(artist_id: from.id, mbid: nil, merged_into_id: nil).filter_map do |entity|
          twins = model.where(artist_id: family, mbid: nil, merged_into_id: nil, normalized_title: entity.normalized_title).pluck(:id)
          [ entity.id, twins.sole ] if twins.size == 1
        end
      end
    end

    def apply_one!(candidate)
      Artist.transaction do
        lock_merges!
        from = candidate.from.reload
        into = candidate.into.reload.resolved
        # Re-checked under the lock: anything changed since the candidates were read wins.
        fresh = candidates_for(candidate.normalized_name).find { |c| c.from.id == from.id }
        next unless fresh&.eligible? && into == fresh.into

        reviews = CatalogueReview.open.where(level: "artist", kind: "possible_match", name_variant_id: fresh.variant_ids)
        inference = record_inference!(fresh.normalized_name, into, from,
                                      { "variants" => fresh.variant_ids.size, "plays" => fresh.plays, "into_mbid" => into.mbid,
                                        "reviews" => reviews.pluck(:id), "albums" => fresh.albums, "tracks" => fresh.tracks })
        from.update!(merged_into: into, inference: inference)
        { Album => fresh.albums, Track => fresh.tracks }.each do |model, pairs|
          pairs.each { |from_id, into_id| model.find(from_id).update!(merged_into_id: into_id, inference: inference) }
        end
        reviews.update_all(state: "resolved", chosen_id: into.id, decided_at: now, inference_id: inference.id, updated_at: now)
        NameVariant.where(id: fresh.variant_ids).update_all(match_version: nil)
        inference
      end
    end

    def record_inference!(name, into, from, evidence)
      inference = CatalogueInference.create_or_find_by!(level: "artist", normalized_name: name, into_id: into.id) do |i|
        i.assign_attributes(rule_version: RULE_VERSION, applied_at: now, evidence: evidence, from: from)
      end
      inference.update!(from: from, evidence: inference.evidence.merge(evidence)) if from && inference.from_id.nil?
      inference
    end

    def blocked?(name, into) = CatalogueInference.reverted.exists?(level: "artist", normalized_name: name, into_id: into.id)

    # A person dismissed a possible match between these variants and these identified artists.
    def dismissed?(variant_ids, identified_ids)
      CatalogueReview.where(level: "artist", kind: "possible_match", state: "dismissed", name_variant_id: variant_ids)
                     .where("candidate_ids && ARRAY[?]::bigint[]", identified_ids.presence || [ 0 ]).exists?
    end

    def disputed?(variants) = variants.any? { |v| MbidDispute.levels_for(v).include?("artist") }

    # A recording or release (linked by MusicBrainz ID) whose artist is another identified artist:
    # evidence that this name may be someone else. An owner counts by the identity it has or would
    # get (`identity`), so the answer doesn't depend on the order inferences are applied in, and a
    # dry run predicts the result.
    def conflicting?(variants, into)
      mbids = { Album => [], Track => [] }
      variants.each do |v|
        disputed = MbidDispute.levels_for(v)
        mbids[Album] << v.album_mbid.downcase if v.album_mbid.present? && !disputed.include?("album")
        mbids[Track] << v.track_mbid.downcase if v.track_mbid.present? && !disputed.include?("track")
      end
      owners = mbids.flat_map { |model, ids| ids.any? ? model.where(mbid: ids.uniq).includes(:artist).map(&:artist) : [] }
      owners.map { |owner| identity(owner) }.uniq.any? { |artist| artist && artist != into }
    end

    # The identified artist an artist is, or would join: itself after merges if identified, else the
    # one identified artist with its name. Nil when there is none or several.
    def identity(artist)
      resolved = artist.resolved
      return resolved if resolved.mbid

      targets = Artist.where(normalized_name: resolved.normalized_name).where.not(mbid: nil).map(&:resolved).uniq
      targets.sole if targets.size == 1 && targets.first.mbid
    end

    # Merges of one kind take turns (Decisions.merge! uses the same lock).
    def lock_merges!
      Artist.connection.execute(Artist.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "catalogue:merge:artist" ]))
    end
  end
end
