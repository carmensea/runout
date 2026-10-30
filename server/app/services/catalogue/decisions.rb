module Catalogue
  # A person's corrections to matching. Each changes only catalogue links and review state, never
  # a name variant's strings or any scrobble, and each is recorded so it can be traced and changed
  # again later.
  module Decisions
    module_function

    # Links one level of a variant to `record`. Re-matching never overrides it. Open reviews for
    # that level are resolved with this choice. Changing the artist re-matches the album and track
    # (unless those were also decided by hand), since they are scoped to the artist.
    def assign!(variant, level, record, by:, clock: Time.current)
      level = level.to_s
      model = Matcher::MODELS.fetch(level)
      raise ArgumentError, "expected #{model.name}, got #{record.class.name}" unless record.is_a?(model)

      HistoryImport.ensure_enabled!
      NameVariant.transaction do
        v = NameVariant.lock.find(variant.id)
        v.update!(Matcher::LINK_COLUMNS.fetch(level) => record.id, "#{level}_match": "manual", matched_at: clock)
        resolve_reviews(v.catalogue_reviews.open.where(level: level), chosen: record, by: by, at: clock)
      end
      Matcher.new(clock: -> { clock }).match!(variant)
    end

    # The person says the candidates are not the same: the review closes and won't reopen for them.
    def dismiss!(review, by:, clock: Time.current)
      review.update!(state: "dismissed", decided_by: by, decided_at: clock)
    end

    # Records that `from` and `into` are one entity: `from` points at `into` from now on, and every
    # variant linked to `from` is re-matched onto `into`. Nothing is deleted, so the decision can be
    # traced (and undone by clearing merged_into and re-matching).
    def merge!(from, into, by:, clock: Time.current)
      raise ArgumentError, "can only merge entities of the same kind" unless from.instance_of?(into.class)

      target = into.resolved
      raise ArgumentError, "can't merge an entity into itself" if target == from || target.resolved == from

      HistoryImport.ensure_enabled!
      level = Matcher::MODELS.key(from.class)
      variants = NameVariant.where(Matcher::LINK_COLUMNS.fetch(level) => from.id)
      from.transaction do
        from.update!(merged_into: target)
        reviews = CatalogueReview.open.where(level: level, name_variant_id: variants.select(:id)).where("? = ANY(candidate_ids)", target.id)
        resolve_reviews(reviews, chosen: target, by: by, at: clock)
      end
      matcher = Matcher.new(clock: -> { clock })
      variants.find_each { |v| matcher.match!(v) }
    end

    # Adds a curated alias. Variants not linked by MBID or by hand are re-matched by the next
    # Matcher#match_pending! run.
    def add_alias!(artist, name, source: "manual")
      HistoryImport.ensure_enabled!
      alias_record = artist.aliases.create!(name: name, source: source)
      NameVariant.where(artist_match: [ nil, "alias", "name", "ambiguous", "unmatched" ]).update_all(match_version: nil)
      alias_record
    end

    def resolve_reviews(reviews, chosen:, by:, at:)
      reviews.find_each { |review| review.update!(state: "resolved", chosen_id: chosen.id, decided_by: by, decided_at: at) }
    end
  end
end
