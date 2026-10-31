module HistoryImport
  # Reconciles a validated snapshot of a month that was already committed (docs/milestone-2-plan.md
  # §4.4). Runs inside WindowCommitter's transaction, under the worker's lease and the per-user lock,
  # so every change below is applied together or not at all. No Last.fm requests.
  #
  # Each second is compared as a multiset: identical plays (same exact artist, track and album
  # strings) are paired first, in any order, duplicates included. MusicBrainz IDs aren't part of a
  # play (Snapshot#play_key): a stored play and a fetched one that differ only in IDs are the same
  # play, and the stored one is kept as it is. Then, per second:
  # - Only fetched plays left over: new plays, inserted after the second's highest `seq` (existing
  #   slots are never reused or renumbered).
  # - Only stored plays left over: missing upstream. The first independent observation records a
  #   suspected removal (`observed`); a later, independently validated snapshot (a different
  #   validation, so a higher fetch attempt) moves it to `pending_review`. Never removed
  #   automatically.
  # - Leftovers on both sides: a dispute for review, with the evidence. Nothing in that second
  #   changes, not even removal bookkeeping, and no play is paired with another automatically.
  #
  # Also: open removal proposals whose play is seen again are closed (`restored`); an approved
  # removal whose play is seen again reopens for review (`reappeared`).
  #
  # Unchanged evidence never reopens a decision. A dismissed removal stays dismissed while its play
  # stays missing; only once the play has been seen again (closing that chain) can a later miss
  # start a new one. A dismissed dispute is reopened only if the evidence for that second changes.
  #
  # Before returning, the result is read back from the database and checked against the snapshot
  # (#verify!). Any disagreement raises WindowCommitter::Inconsistent: the whole transaction rolls
  # back and the month goes to review instead of being reported as reconciled.
  #
  # Publishes `reconcile.history_import` with the plays it meant to insert and the ids actually
  # inserted, for tests and diagnostics. (Synthetic data only should ever be logged from it.)
  class Reconciler
    SOURCE = "reconciliation".freeze
    EVENT = "reconcile.history_import".freeze
    # A snapshot lacking more than half of the stored plays in the range (when there are at least
    # this many) looks like an incomplete answer from Last.fm, not like deletions: the check goes
    # to review instead of recording removals.
    MASS_DISAPPEARANCE_MIN = 20

    # `range`: the part of the window being checked (the whole window by default).
    def initialize(window:, fetch:, rows:, variant_ids:, now:, range: window.window_from...window.window_to)
      @window = window
      @fetch = fetch
      @rows = rows
      @variant_ids = variant_ids
      @now = now
      @range = range
      @summary = Hash.new(0)
      @inserts = []
      @disputed = Set.new
      @missing = []
    end

    # Returns counts of what happened, for the window's last_check_summary.
    def call
      stored = stored_plays
      @removals = ScrobbleRemoval.where(scrobble_id: stored.map(&:id)).order(:id).group_by(&:scrobble_id)
      @disputes = ReconciliationDispute.where(user_id: @window.user_id, played_at: @range, state: %w[open dismissed])
                                       .order(:id).group_by { |d| d.played_at.to_i }
      staged = @rows.group_by { |row| row.played_at.to_i }
      stored_by_second = stored.group_by { |s| s.played_at.to_i }
      refuse_mass_disappearance!(staged, stored_by_second)
      (staged.keys | stored_by_second.keys).sort.each { |t| reconcile_second(t, staged.fetch(t, []), stored_by_second.fetch(t, [])) }

      inserted = @inserts.each_slice(WindowCommitter::BATCH).flat_map { |batch| Scrobble.insert_all!(batch, returning: %w[id]).rows.flatten }
      ActiveSupport::Notifications.instrument(EVENT, window_id: @window.id, fetch_id: @fetch.id, intended: @inserts, inserted_ids: inserted)
      verify!(stored, staged, inserted)

      @summary[:added] = @inserts.size
      @summary.to_h
    end

    private

    # Every play in the month, removed ones included, with its variant's strings. Read from the
    # database, never from the query cache: writes by other processes don't clear it.
    def stored_plays
      Scrobble.uncached do
        Scrobble.where(user_id: @window.user_id).played_between(@range.begin, @range.end).joins(:name_variant)
                .select("scrobbles.*, name_variants.artist_name, name_variants.track_name, name_variants.album_name").to_a
      end
    end

    # A play within its second: its exact strings, without IDs. Stored plays and staged rows alike.
    def play(record) = [ record.artist_name, record.track_name, record.album_name.to_s ]

    # The month as stored now must be exactly what the rules above produce from the snapshot:
    # - every play stored before is still there, unchanged (same slot, variant and removal state);
    # - the only new plays are the ones this check inserted;
    # - in a second without a dispute, each distinct play is stored as many times as the larger of
    #   the stored and fetched counts: every fetched play is represented, same-second duplicates
    #   are kept, and nothing is added twice;
    # - a disputed second is exactly as it was;
    # - every stored play the snapshot lacks has an open or dismissed removal record.
    def verify!(before, staged, inserted_ids)
      fail!("inserted #{inserted_ids.size} plays, meant to insert #{@inserts.size}") unless inserted_ids.size == @inserts.size

      after = stored_plays
      now_by_id = after.index_by(&:id)
      unchanged = before.all? do |s|
        (a = now_by_id[s.id]) && [ a.played_at, a.seq, a.name_variant_id, a.removed_at ] == [ s.played_at, s.seq, s.name_variant_id, s.removed_at ]
      end
      fail!("a stored play changed or disappeared") unless unchanged
      fail!("plays appeared that this check didn't insert") unless (now_by_id.keys - before.map(&:id)).sort == inserted_ids.sort

      had = before.group_by { |s| s.played_at.to_i }
      has = after.group_by { |s| s.played_at.to_i }
      (staged.keys | has.keys).each do |t|
        was = had.fetch(t, []).map { |s| play(s) }.tally
        now = has.fetch(t, []).map { |s| play(s) }.tally
        if @disputed.include?(t)
          fail!("a disputed second changed") unless now == was
          next
        end

        fetched = staged.fetch(t, []).map { |row| play(row) }.tally
        (fetched.keys | now.keys).each do |h|
          fail!("a second's plays don't match the snapshot") unless now.fetch(h, 0) == [ was.fetch(h, 0), fetched.fetch(h, 0) ].max
        end
      end

      flagged = ScrobbleRemoval.uncached do
        ScrobbleRemoval.where(scrobble_id: @missing).order(:id).group_by(&:scrobble_id).transform_values { |r| r.last.state }
      end
      fail!("a missing play has no removal record") unless @missing.all? { |id| %w[observed pending_review dismissed].include?(flagged[id]) }
    end

    def fail!(message) = raise(WindowCommitter::Inconsistent.new("reconciliation check failed: #{message}", reason: "reconciliation_check"))

    # Counted before anything is written: present plays the snapshot has no identical play for.
    def refuse_mass_disappearance!(staged, stored_by_second)
      present = stored_by_second.values.flatten.count { |s| s.removed_at.nil? }
      return if present < MASS_DISAPPEARANCE_MIN

      missing = stored_by_second.sum do |t, plays|
        fetched = staged.fetch(t, []).map { |row| play(row) }.tally
        plays.select { |s| s.removed_at.nil? }.map { |s| play(s) }.tally.sum { |h, n| [ n - fetched.fetch(h, 0), 0 ].max }
      end
      return unless missing * 2 > present

      raise WindowCommitter::Inconsistent.new("the snapshot lacks #{missing} of #{present} stored plays; not treated as deletions " \
                                              "(an incomplete answer?)", reason: "incomplete_answer")
    end

    def reconcile_second(t, staged, stored)
      pools = Hash.new { |h, k| h[k] = [] }
      # Present plays are matched before removed ones, each in slot order.
      stored.sort_by { |s| [ s.removed_at ? 1 : 0, s.seq ] }.each { |s| pools[play(s)] << s }
      matched = []
      unmatched_staged = []
      staged.each { |row| (s = pools[play(row)].shift) ? matched << s : unmatched_staged << row }
      unmatched_present = pools.values.flatten.select { |s| s.removed_at.nil? }
      open = @disputes.fetch(t, []).find { |d| d.state == "open" }

      if unmatched_staged.any? && unmatched_present.any?
        @disputed << t
        dispute!(t, unmatched_present, unmatched_staged, open)
        return
      end

      supersede!(open, "the second is no longer ambiguous") if open
      @summary[:matched] += matched.size
      matched.each { |s| s.removed_at ? reappeared!(s) : seen!(s) }
      next_seq = stored.map(&:seq).max.to_i + (stored.any? ? 1 : 0)
      unmatched_staged.each_with_index do |row, i|
        @inserts << { user_id: @window.user_id, played_at: row.played_at, seq: next_seq + i,
                      name_variant_id: @variant_ids.fetch(row.variant_hash), first_seen_fetch_id: @fetch.id }
      end
      unmatched_present.each { |s| missing!(s) }
    end

    def dispute!(t, present, staged_rows, open)
      stored_ids = present.map(&:id).sort
      proposed = staged_rows.map { |row| @variant_ids.fetch(row.variant_hash) }.sort
      key = ReconciliationDispute.evidence_key(stored_ids, proposed)
      if open&.evidence_key == key
        open.update!(last_seen_fetch_id: @fetch.id) unless open.last_seen_fetch_id == @fetch.id
        @summary[:disputes_unchanged] += 1
        return
      end

      supersede!(open, "the evidence changed") if open
      if @disputes.fetch(t, []).any? { |d| d.state == "dismissed" && d.evidence_key == key }
        @summary[:disputes_dismissed_unchanged] += 1 # same evidence a person already looked at
        return
      end

      dispute = ReconciliationDispute.create!(user_id: @window.user_id, import_window: @window, played_at: Time.at(t).utc,
                                              stored_scrobble_ids: stored_ids, proposed_variant_ids: proposed, evidence_key: key,
                                              first_seen_fetch: @fetch, last_seen_fetch: @fetch)
      # The stored plays' variants as they were, kept with the audit record: a later correction
      # re-points a play to another variant, and the dispute row holds only the play ids.
      ReviewDecision.record!(dispute, :opened, source: SOURCE, fetch_id: @fetch.id,
                             stored_variant_ids: present.sort_by(&:id).map(&:name_variant_id))
      @summary[:disputes_opened] += 1
    end

    def supersede!(dispute, reason)
      dispute.update!(state: "superseded")
      ReviewDecision.record!(dispute, :superseded, source: SOURCE, fetch_id: @fetch.id, reason: reason)
    end

    def latest_removal(scrobble) = @removals.fetch(scrobble.id, []).last

    def seen!(scrobble)
      removal = latest_removal(scrobble)
      return unless removal && %w[observed pending_review dismissed].include?(removal.state)

      action = removal.state == "dismissed" ? :seen_after_dismissal : :seen_again
      removal.update!(state: "restored")
      ReviewDecision.record!(removal, action, source: SOURCE, fetch_id: @fetch.id)
      @summary[:removals_closed] += 1
    end

    def reappeared!(scrobble)
      removal = latest_removal(scrobble)
      return unless removal&.state == "approved"

      removal.update!(state: "reappeared")
      ReviewDecision.record!(removal, :reappeared, source: SOURCE, fetch_id: @fetch.id)
      @summary[:removals_reappeared] += 1
    end

    def missing!(scrobble)
      @missing << scrobble.id
      removal = latest_removal(scrobble)
      case removal&.state
      when nil, "restored"
        created = ScrobbleRemoval.create!(user_id: scrobble.user_id, scrobble_id: scrobble.id, first_missing_fetch: @fetch)
        ReviewDecision.record!(created, :observed, source: SOURCE, fetch_id: @fetch.id)
        @summary[:removals_observed] += 1
      when "observed"
        # Only an independent validation confirms: a later fetch, not a replay of the same snapshot.
        return unless @fetch.attempt > removal.first_missing_fetch.attempt

        removal.update!(state: "pending_review", confirming_fetch: @fetch)
        ReviewDecision.record!(removal, :confirmed, source: SOURCE, fetch_id: @fetch.id)
        @summary[:removals_pending_review] += 1
      end
      # pending_review: already waiting for a person. dismissed: unchanged evidence, stays dismissed.
    end
  end
end
