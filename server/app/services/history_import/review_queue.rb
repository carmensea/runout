module HistoryImport
  # The review queue for the app (docs/milestone-2-plan.md §15.2): actionable items with their
  # evidence, oldest play first. Actionable: removals pending review, reappeared plays, open
  # disputes. Removals seen only once are counted (`waiting`) but not listed: they need a second
  # independent check before anyone can decide. Catalogue suggestions are not part of it.
  #
  # Each item carries `version` (Review.version); a decision sent with it is refused if the item
  # changed meanwhile. Names are the exact strings stored and the exact strings Last.fm returned.
  module ReviewQueue
    module_function

    def for(user, limit: 50, offset: 0)
      removals = ScrobbleRemoval.where(user_id: user.id, state: %w[pending_review reappeared])
                                .includes(:first_missing_fetch, :confirming_fetch, scrobble: :name_variant).to_a
      disputes = ReconciliationDispute.open.where(user_id: user.id).to_a
      stored = Scrobble.where(id: disputes.flat_map(&:stored_scrobble_ids)).includes(:name_variant).index_by(&:id)
      variants = NameVariant.where(id: disputes.flat_map(&:proposed_variant_ids)).index_by(&:id)
      items = removals.map { |r| removal_json(r) } + disputes.map { |d| dispute_json(d, stored, variants) }
      items.sort_by! { |i| [ i[:playedAt], i[:kind], i[:id] ] }
      page = items.drop(offset).first(limit)
      history = ReviewDecision.where(user_id: user.id).where(history_condition(page)).order(:created_at, :id)
                              .group_by { |d| [ d.subject_type, d.subject_id ] }
      page.each do |i|
        i[:history] = history.fetch([ i[:subjectType], i[:id] ], []).map { |d| { action: d.action, source: d.source, at: d.created_at.iso8601 } }
      end
      { items: page, total: items.size, offset: offset,
        waiting: ScrobbleRemoval.where(user_id: user.id, state: "observed").count }
    end

    def removal_json(r)
      s = r.scrobble
      { kind: r.state == "reappeared" ? "reappeared" : "removal", subjectType: "ScrobbleRemoval", id: r.id, version: Review.version(r),
        playedAt: s.played_at.iso8601, play: play_json(s), removedAt: s.removed_at&.iso8601,
        firstMissingAt: (r.first_missing_fetch.finished_at || r.created_at).iso8601,
        confirmedMissingAt: r.confirming_fetch&.finished_at&.iso8601 }
    end

    def dispute_json(d, stored, variants)
      { kind: "dispute", subjectType: "ReconciliationDispute", id: d.id, version: Review.version(d), playedAt: d.played_at.iso8601,
        stored: d.stored_scrobble_ids.filter_map { |id| stored[id] }.sort_by(&:seq).map { |s| play_json(s) },
        fetched: d.proposed_variant_ids.each_with_index.map { |id, index| names(variants.fetch(id)).merge(index: index) },
        firstSeenAt: d.created_at.iso8601, lastSeenAt: d.updated_at.iso8601 }
    end

    def play_json(s) = names(s.name_variant).merge(id: s.id, seq: s.seq)

    def names(v) = { artist: v.artist_name, track: v.track_name, album: v.album_name.presence }

    def history_condition(page)
      return "1 = 0" if page.empty?

      page.group_by { |i| i[:subjectType] }
          .map { |type, items| ReviewDecision.sanitize_sql_array([ "(subject_type = ? AND subject_id IN (?))", type, items.map { |i| i[:id] } ]) }
          .join(" OR ")
    end
  end
end
