module HistoryImport
  # A person's decisions on reconciliation review items (docs/milestone-2-plan.md §4.4). The
  # command-line tasks (lib/tasks/review.rake) call these; a frontend can call them later.
  #
  # Every decision:
  # - runs in one transaction holding the same per-user lock as reconciliation, plus the item's
  #   row lock, so it never interleaves with a commit or another decision;
  # - re-checks the item's state first, so retrying a decision that already happened changes
  #   nothing and returns :already;
  # - is recorded in review_decisions with who decided, the source, and the details.
  #
  # Nothing is hard-deleted. Removing a play sets scrobbles.removed_at; a correction re-points the
  # play to another immutable name variant and records the old one in scrobble_corrections.
  module Review
    class Invalid < StandardError; end
    # The item changed after the reviewer loaded it (another decision, or a later check): nothing
    # was decided. The caller shows the item as it is now.
    class Changed < StandardError; end

    # Identifies the version of an item a reviewer saw. Any change to the item changes it.
    def self.version(item) = item.updated_at.utc.iso8601(6)

    module_function

    # Unresolved items for the user, oldest first.
    def pending(user)
      { disputes: ReconciliationDispute.open.where(user: user).order(:played_at).to_a,
        removals: ScrobbleRemoval.unresolved.where(user: user).includes(scrobble: :name_variant).order(:id).to_a }
    end

    def approve_removal!(removal, by:, note: nil, source: "cli", expected_version: nil)
      decide(removal, ScrobbleRemoval) do |r|
        next :already if r.state == "approved"
        check_version!(r, expected_version)
        raise Invalid, "only a removal pending review can be approved (this one is #{r.state})" unless r.state == "pending_review"

        now = Time.current
        r.update!(state: "approved", decided_at: now, decided_by: by, decision_note: note)
        r.scrobble.update!(removed_at: now)
        refresh_window_count(r.user_id, r.scrobble.played_at)
        ReviewDecision.record!(r, :approved, source: source, by: by, note: note, scrobble_id: r.scrobble_id)
        :approved
      end
    end

    def dismiss_removal!(removal, by:, note: nil, source: "cli", expected_version: nil)
      decide(removal, ScrobbleRemoval) do |r|
        next :already if r.state == "dismissed"
        check_version!(r, expected_version)
        raise Invalid, "only an open removal can be dismissed (this one is #{r.state})" unless %w[observed pending_review].include?(r.state)

        r.update!(state: "dismissed", decided_at: Time.current, decided_by: by, decision_note: note)
        ReviewDecision.record!(r, :dismissed, source: source, by: by, note: note, scrobble_id: r.scrobble_id)
        :dismissed
      end
    end

    # A removed play that Last.fm returns again: bring it back.
    def restore_reappeared!(removal, by:, note: nil, source: "cli", expected_version: nil)
      decide(removal, ScrobbleRemoval) do |r|
        next :already if r.state == "restored"
        check_version!(r, expected_version)
        raise Invalid, "only a reappeared play can be restored (this one is #{r.state})" unless r.state == "reappeared"

        r.update!(state: "restored", decided_at: Time.current, decided_by: by, decision_note: note)
        r.scrobble.update!(removed_at: nil)
        refresh_window_count(r.user_id, r.scrobble.played_at)
        ReviewDecision.record!(r, :restored, source: source, by: by, note: note, scrobble_id: r.scrobble_id)
        :restored
      end
    end

    # A removed play that Last.fm returns again: keep it removed.
    def keep_removed!(removal, by:, note: nil, source: "cli", expected_version: nil)
      decide(removal, ScrobbleRemoval) do |r|
        next :already if r.state == "approved"
        check_version!(r, expected_version)
        raise Invalid, "only a reappeared play can be kept removed (this one is #{r.state})" unless r.state == "reappeared"

        r.update!(state: "approved", decided_at: Time.current, decided_by: by, decision_note: note)
        ReviewDecision.record!(r, :kept_removed, source: source, by: by, note: note, scrobble_id: r.scrobble_id)
        :kept_removed
      end
    end

    # Resolves a disputed second. `pairs` are the reviewer's explicit matches,
    # [[stored scrobble id, index into proposed_variant_ids], ...]; each becomes an applied
    # correction. Nothing is paired that the reviewer didn't pair:
    # - fetched plays left unpaired are added as new plays (after the second's highest slot);
    # - stored plays left unpaired are not removed: they start the usual removal process
    #   (`observed`), which needs a later independent check and an approval.
    # With no pairs, every fetched play is new and every stored play is suspected missing.
    def resolve_dispute!(dispute, by:, pairs: [], note: nil, source: "cli", expected_version: nil)
      decide(dispute, ReconciliationDispute) do |d|
        next :already if d.state == "resolved"
        check_version!(d, expected_version)
        raise Invalid, "only an open dispute can be resolved (this one is #{d.state})" unless d.state == "open"

        pairs = validate_pairs!(d, pairs)
        stored = Scrobble.where(id: d.stored_scrobble_ids).lock.index_by(&:id)
        unless stored.size == d.stored_scrobble_ids.size && stored.values.all? { |s| s.removed_at.nil? }
          raise Invalid, "the stored plays changed since this dispute was recorded; check the month again"
        end

        now = Time.current
        corrections = pairs.map do |scrobble_id, index|
          scrobble = stored.fetch(scrobble_id)
          to_variant_id = d.proposed_variant_ids.fetch(index)
          correction = ScrobbleCorrection.create!(user_id: d.user_id, scrobble: scrobble, from_variant_id: scrobble.name_variant_id,
                                                  to_variant_id: to_variant_id, import_window_fetch_id: d.last_seen_fetch_id,
                                                  state: "applied", reason: "dispute #{d.id} resolved by review",
                                                  decided_at: now, decided_by: by, decision_note: note)
          scrobble.update!(name_variant_id: to_variant_id)
          correction.id
        end

        paired_indexes = pairs.map(&:last)
        new_variant_ids = d.proposed_variant_ids.each_with_index.reject { |_, i| paired_indexes.include?(i) }.map(&:first)
        next_seq = Scrobble.where(user_id: d.user_id, played_at: d.played_at).maximum(:seq).to_i + 1
        added = new_variant_ids.each_with_index.map do |variant_id, i|
          Scrobble.create!(user_id: d.user_id, played_at: d.played_at, seq: next_seq + i, name_variant_id: variant_id,
                           first_seen_fetch_id: d.last_seen_fetch_id).id
        end

        unpaired = d.stored_scrobble_ids - pairs.map(&:first)
        observed = unpaired.filter_map do |scrobble_id|
          next if ScrobbleRemoval.unresolved.exists?(scrobble_id: scrobble_id)

          ScrobbleRemoval.create!(user_id: d.user_id, scrobble_id: scrobble_id, first_missing_fetch_id: d.last_seen_fetch_id).id
        end

        resolution = { pairs: pairs, corrections: corrections, added_scrobbles: added, removals_observed: observed }
        d.update!(state: "resolved", decided_at: now, decided_by: by, resolution: resolution)
        refresh_window_count(d.user_id, d.played_at)
        ReviewDecision.record!(d, :resolved, source: source, by: by, note: note, **resolution)
        :resolved
      end
    end

    # Keeps the stored plays as they are. The same evidence won't reopen the dispute; a later check
    # that sees different plays in that second opens a new one.
    def dismiss_dispute!(dispute, by:, note: nil, source: "cli", expected_version: nil)
      decide(dispute, ReconciliationDispute) do |d|
        next :already if d.state == "dismissed"
        check_version!(d, expected_version)
        raise Invalid, "only an open dispute can be dismissed (this one is #{d.state})" unless d.state == "open"

        d.update!(state: "dismissed", decided_at: Time.current, decided_by: by, resolution: { note: note })
        ReviewDecision.record!(d, :dismissed, source: source, by: by, note: note)
        :dismissed
      end
    end

    # Uncached, like WindowCommitter#commit: decisions must read what is stored now.
    def check_version!(item, expected)
      raise Changed, "this item changed since it was loaded; review it again" if expected && version(item) != expected
    end

    def decide(item, model)
      HistoryImport.ensure_enabled!
      model.uncached do
        model.transaction do
          model.connection.execute(model.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "history:#{item.user_id}" ]))
          yield model.lock.find(item.id)
        end
      end
    end

    def validate_pairs!(dispute, pairs)
      pairs = Array(pairs).map { |scrobble_id, index| [ Integer(scrobble_id), Integer(index) ] }
      unless pairs.all? { |id, i| dispute.stored_scrobble_ids.include?(id) && (0...dispute.proposed_variant_ids.size).cover?(i) }
        raise Invalid, "pairs must name stored plays of this dispute and indexes of its fetched plays"
      end
      raise Invalid, "a stored play can be paired only once" unless pairs.map(&:first).uniq.size == pairs.size
      raise Invalid, "a fetched play can be paired only once" unless pairs.map(&:last).uniq.size == pairs.size

      pairs
    end

    # committed_count is the plays present in the month; decisions can change it.
    def refresh_window_count(user_id, played_at)
      window = ImportWindow.live.imported.where(user_id: user_id).find_by("window_from <= ? AND window_to > ?", played_at, played_at)
      return unless window

      present = Scrobble.present.where(user_id: user_id).played_between(window.window_from, window.window_to).count
      ImportWindow.where(id: window.id).update_all(committed_count: present, present_count: present, count_mismatch_at: nil, updated_at: Time.current)
    end
  end
end
