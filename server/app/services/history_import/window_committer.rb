module HistoryImport
  # Commits one validated window into permanent storage (docs/milestone-2-plan.md §4.4). Makes no
  # Last.fm requests.
  #
  # Everything happens in one transaction under the worker's lease and a per-user advisory lock:
  # re-check the window and its staged snapshot, insert name variants and scrobbles, mark the
  # window committed with its count. Any failure rolls the whole transaction back, so a window is
  # never partly committed and never marked committed before its plays are stored. The window
  # then returns to `validated` with its staging intact, ready for another attempt.
  #
  # - A window never committed before: its range must hold no plays; they're all inserted. (Plays in
  #   a never-committed range would mean something wrote outside this path: review, nothing written.)
  # - A window committed before (a later check of the month): the snapshot is reconciled with the
  #   stored plays (HistoryImport::Reconciler) in the same transaction.
  # Either way the window ends `committed` with committed_count = the plays present, and
  # last_checked_at records this successful check against Last.fm.
  #
  # A check may cover only part of the window (ImportWindow#check_range, set by SyncPlanner): only
  # that part is reconciled. If it ends past window_to, the window grows to its end here, in the
  # same transaction, so coverage never includes a range before its plays are committed.
  # last_verified_at is set only when the whole window was checked.
  #
  # `seq` is each play's position within its second in the validated snapshot. It is a storage
  # slot only, not an identity that later fetches can be matched on.
  class WindowCommitter
    Outcome = Data.define(:status, :detail)

    # The staged snapshot can't be trusted; the window is left for review with its staging kept.
    class Inconsistent < StandardError
      attr_reader :reason

      def initialize(message = nil, reason: "staging_inconsistent")
        super(message)
        @reason = reason
      end
    end
    # The snapshot is older than StagingCleaner::STALE_AFTER: fetched again before any commit.
    class Expired < StandardError; end

    BATCH = 1_000
    # Failed commits retried automatically (with ImportWindow::RETRY_DELAYS) before the window stops
    # as `failed` for a person to retry.
    MAX_COMMIT_ATTEMPTS = 3
    # Errors worth retrying: the database was briefly unavailable or contended. Anything else, such
    # as a constraint violation, is a data-integrity problem and goes to review instead.
    TRANSIENT_ERRORS = [ ActiveRecord::ConnectionNotEstablished, ActiveRecord::ConnectionFailed, ActiveRecord::Deadlocked,
                         ActiveRecord::LockWaitTimeout, ActiveRecord::QueryCanceled, ActiveRecord::SerializationFailure,
                         ActiveRecord::AdapterTimeout ].freeze

    def initialize(window:, token: SecureRandom.uuid, clock: -> { Time.current })
      @window = window
      @token = token
      @clock = clock
    end

    def call
      HistoryImport.ensure_enabled!
      return outcome(:not_claimed, "window is not available to commit") unless claim

      count = commit
      StagingCleaner.new(clock: @clock).clean_window(@window)
      outcome(:committed, "#{count} plays")
    rescue Inconsistent => e
      review(e.message, reason: e.reason)
    rescue Expired => e
      refetch(e.message)
    rescue ImportWindow::StaleLease => e
      outcome(:stale, e.message)
    rescue HistoryImport::DisabledError
      raise
    rescue StandardError => e
      retry_later(e)
    end

    private

    def now = @clock.call

    def outcome(status, detail = nil) = Outcome.new(status: status, detail: detail)

    # Takes a validated window, or one whose committing worker died (its lease expired). One
    # conditional UPDATE, so only one worker wins.
    def claim
      claimed = ImportWindow.where(id: @window.id, state: %w[validated committing])
                            .where("claim_token IS NULL OR lease_expires_at < ?", now)
                            .update_all([ "state = 'committing', claim_token = ?, lease_expires_at = ?, updated_at = ?",
                                          @token, now + ImportWindow::LEASE, now ])
      @window.reload if claimed == 1
      claimed == 1
    end

    # Uncached throughout: jobs run with Rails' query cache on, and writes by other processes don't
    # clear it, so a repeated read could return an earlier result.
    def commit
      ImportWindow.uncached { commit_under_lease }
    end

    def commit_under_lease
      @window.with_lease(@token, now: now) do |window|
        HistoryImport.ensure_enabled!
        raise ImportWindow::StaleLease, "window #{window.id} is #{window.state}, not committing" unless window.state == "committing"
        raise Expired, "validated snapshot is older than #{StagingCleaner::STALE_AFTER.inspect}" if window.validated_at < now - StagingCleaner::STALE_AFTER

        ImportWindow.connection.execute(ImportWindow.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", "history:#{window.user_id}" ]))
        rows = staged_rows(window)
        range = window.check_range
        if window.committed_at
          variant_ids = store_variants(rows)
          summary = Reconciler.new(window: window, fetch: @fetch, rows: rows, variant_ids: variant_ids, now: now, range: range).call
          added = summary[:added]
        else
          raise Inconsistent, "a window never committed must be checked whole" unless range == (window.window_from...window.window_to)

          check_range_is_empty(window)
          variant_ids = store_variants(rows)
          added = store_scrobbles(window, rows, variant_ids)
          stored = Scrobble.from_lastfm.where(user_id: window.user_id).played_between(window.window_from, window.window_to).count
          raise "stored #{stored} plays, expected #{rows.size}" unless added == rows.size && stored == rows.size

          summary = { added: added }
        end

        verified = window.whole_window_checked?
        window.window_to = range.end if range.end > window.window_to
        present = Scrobble.from_lastfm.present.where(user_id: window.user_id).played_between(window.window_from, window.window_to).count
        window.assign_attributes(state: "committed", committed_at: window.committed_at || now, committed_count: present,
                                 last_checked_at: now, last_check_fetch_id: @fetch.id, last_check_summary: summary,
                                 check_from: nil, check_to: nil, claim_token: nil, lease_expires_at: nil, last_error_message: nil, retry_at: nil,
                                 review_reason: nil, present_count: present, count_mismatch_at: nil)
        window.last_verified_at = now if verified
        ImportRun.where(id: window.import_run_id).update_all([ "committed_scrobbles = committed_scrobbles + ?, updated_at = ?", added, now ])
        added
      end
    end

    # The staged rows of the validated snapshot, checked against everything recorded about it.
    def staged_rows(window)
      fetch = window.fetches.where(outcome: "validated").order(:attempt).last
      raise Inconsistent, "no validated fetch to commit" unless fetch

      rows = fetch.rows.order(:played_at, :position).to_a
      counts = [ rows.size, fetch.row_count, window.fetched_count, window.expected_total ]
      raise Inconsistent, "staged snapshot is incomplete (staged, fetched, recorded, reported: #{counts.join(', ')})" unless counts.uniq.size == 1

      range = window.check_range
      raise Inconsistent, "staged plays lie outside the range checked" unless rows.all? { |row| range.cover?(row.played_at) }

      rows.group_by(&:played_at).each_value do |second|
        raise Inconsistent, "staged positions within a second are not contiguous" unless second.map(&:position) == (0...second.size).to_a

        second.group_by(&:variant_hash).each_value do |same|
          raise Inconsistent, "staged occurrences within a second are not contiguous" unless same.map(&:occurrence).sort == (0...same.size).to_a
        end
      end
      raise Inconsistent, "staged strings don't match their variant hash" unless rows.all? { |row| NameVariant.hash_for(fields(row)) == row.variant_hash }

      @fetch = fetch
      rows
    end

    def check_range_is_empty(window)
      return unless Scrobble.from_lastfm.where(user_id: window.user_id).played_between(window.window_from, window.window_to).exists?

      raise Inconsistent, "plays are already stored in a range that was never committed"
    end

    # Name variants are shared and immutable: existing ones are reused, never changed. Each one
    # found is checked against the staged strings before plays link to it.
    def store_variants(rows)
      unique = rows.uniq(&:variant_hash).map { |row| fields(row).merge(variant_hash: row.variant_hash) }.index_by { |v| v[:variant_hash] }
      unique.values.each_slice(BATCH) { |batch| NameVariant.insert_all(batch, unique_by: :variant_hash) }
      ids = {}
      NameVariant.where(variant_hash: unique.keys).find_each do |variant|
        expected = unique.fetch(variant.variant_hash)
        mismatch = NameVariant::IDENTITY_FIELDS.any? { |field| variant[field] != expected[field] }
        raise Inconsistent, "a stored name variant doesn't match its hash" if mismatch

        ids[variant.variant_hash] = variant.id
      end
      raise "missing name variants after insert" unless ids.size == unique.size

      ids
    end

    # Slots follow the snapshot's positions, after any held by other sources' plays in that second.
    def store_scrobbles(window, rows, variant_ids)
      other = Scrobble.where(user_id: window.user_id).where.not(source: "lastfm").played_between(window.window_from, window.window_to)
                      .group(:played_at).maximum(:seq).transform_keys(&:to_i)
      records = rows.map do |row|
        { user_id: window.user_id, played_at: row.played_at, seq: row.position + (other.key?(row.played_at.to_i) ? other[row.played_at.to_i] + 1 : 0),
          name_variant_id: variant_ids.fetch(row.variant_hash), first_seen_fetch_id: @fetch.id }
      end
      records.each_slice(BATCH).sum { |batch| Scrobble.insert_all!(batch).length }
    end

    def fields(row)
      NameVariant::IDENTITY_FIELDS.index_with { |field| row[field] }
    end

    def review(message, reason:)
      @window.with_lease(@token, now: now) do |window|
        window.assign_attributes(state: "needs_review", review_reason: reason, last_error_message: message, claim_token: nil,
                                 lease_expires_at: nil)
      end
      outcome(:needs_review, message)
    rescue ImportWindow::StaleLease => e
      outcome(:stale, e.message)
    end

    # The commit rolled back. Only the error's class and first line are kept: database messages can
    # quote row contents on later lines.
    # - A transient error: back to `validated`, staging untouched, retried after a delay, at most
    #   MAX_COMMIT_ATTEMPTS times. Then `failed` with no retry, for a person to retry.
    # - Anything else: `needs_review`, staging kept for investigation.
    def retry_later(error)
      message = "commit failed: #{error.class.name}: #{error.message.to_s.lines.first.to_s.strip.truncate(200)}"
      return review(message, reason: "commit_error") unless TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) }

      @window.with_lease(@token, now: now) do |window|
        window.commit_attempts += 1
        if window.commit_attempts >= MAX_COMMIT_ATTEMPTS
          window.assign_attributes(state: "failed", retry_at: nil, last_error_message: "#{message} (gave up after #{window.commit_attempts} attempts)")
        else
          window.assign_attributes(state: "validated", retry_at: now + ImportWindow.retry_delay(window.commit_attempts),
                                   last_error_message: message)
        end
        window.assign_attributes(claim_token: nil, lease_expires_at: nil)
      end
      outcome(:failed, message)
    rescue ImportWindow::StaleLease => e
      outcome(:stale, e.message)
    end

    # The snapshot is too old to trust: drop it and fetch the window again.
    def refetch(message)
      @window.with_lease(@token, now: now) do |window|
        ImportWindowRow.where(import_window_fetch_id: window.fetches.select(:id)).delete_all
        window.assign_attributes(state: "pending", validated_at: nil, fetched_count: nil, expected_total: nil, retry_at: nil,
                                 claim_token: nil, lease_expires_at: nil, last_error_message: "#{message}; fetching again")
      end
      outcome(:expired, message)
    rescue ImportWindow::StaleLease => e
      outcome(:stale, e.message)
    end
  end
end
