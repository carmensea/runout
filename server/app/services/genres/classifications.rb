module Genres
  # Rebuilds the derived genre classification of artists from their provider genres and tags and the
  # owner's overrides (docs/milestone-4-plan.md §3). Nothing here fetches anything; it can run at any
  # time, for some artists or all.
  #
  # Signals: the provider's curated genres, plus free-form tags that the taxonomy maps (and that
  # aren't also listed as genres, since MusicBrainz repeats genres among its tags). Unmapped tags are
  # left out before weighting, so "seen live" never dilutes a real genre. An override of `genres`
  # replaces the provider's signals entirely.
  module Classifications
    module_function

    def recompute!(mbids = nil, now: Time.current)
      classifier = Classifier.from_database
      mapped = TagGenreMapping.distinct.pluck(:tag).to_set
      scope = MetadataTag.where(entity_kind: "artist")
      scope = scope.where(provider_id: mbids) if mbids
      tags = scope.pluck(:provider_id, :kind, :name, :votes).group_by(&:first)
      overrides = MetadataOverride.where(entity_kind: "artist", field: "genres")
      overrides = overrides.where(provider_id: mbids) if mbids
      overrides = overrides.pluck(:provider_id, :value).to_h
      known = MetadataArtist.where(provider: Metadata::Enrichment::PROVIDER)
      known = known.where(provider_id: mbids) if mbids
      ids = (known.pluck(:provider_id) + overrides.keys).uniq

      rows = ids.map do |mbid|
        if (override = overrides[mbid])
          result = from_override(classifier, override)
          basis = "override"
        else
          list = tags.fetch(mbid, [])
          genres = list.select { |_, kind, _, _| kind == "genre" }
          genre_names = genres.map { |_, _, name, _| TagGenreMapping.normalize(name) }.to_set
          extra = list.select { |_, kind, name, _| kind == "tag" && mapped.include?(TagGenreMapping.normalize(name)) && !genre_names.include?(TagGenreMapping.normalize(name)) }
          result = classifier.call((genres + extra).map { |_, _, name, votes| { name: name, votes: votes } })
          basis = Metadata::Enrichment::PROVIDER
        end
        { level: "artist", provider_id: mbid, basis: basis, unclassified: result.unclassified?, broad: result.broad, sub: result.sub,
          present: result.present.to_a.sort, signals_used: result.signals_used, computed_at: now }
      end
      GenreClassification.where(level: "artist").where.not(provider_id: ids).where(provider_id: mbids).delete_all if mbids
      GenreClassification.where(level: "artist").where.not(provider_id: ids).delete_all unless mbids
      rows.each_slice(1000) { |batch| GenreClassification.upsert_all(batch, unique_by: %i[level provider_id]) }
      rows.size
    end

    # An override names genres and weights directly; they are treated as votes on a name that maps
    # to exactly that genre.
    def from_override(classifier, value)
      genres = Genre.includes(:parent).to_h { |g| [ g.slug, [ g.level, g.parent&.slug ] ] }
      mappings = Array(value).to_h { |g| [ "override:#{g['genre']}", [ [ g["genre"], 1.0 ] ] ] }
      Classifier.new(mappings: mappings, genres: genres, settings: { "min_tag_weight" => 0, "min_mapped_weight" => 0 })
                .call(Array(value).map { |g| { name: "override:#{g['genre']}", votes: g["weight"].to_f } })
    end
  end
end
