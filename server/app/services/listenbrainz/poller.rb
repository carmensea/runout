module Listenbrainz
  # One poll of a connected ListenBrainz account (docs/listenbrainz-spotify-feasibility.md §4.2),
  # reading public listens and recording them through Listening::Recorder. Like Spotify::Poller:
  #
  # - One poll per source at a time (a session-level advisory lock; a poll that can't take it does
  #   nothing).
  # - The cursor is `high_water_at`, the newest listen recorded. A poll reads newest-first with
  #   `max_ts` paging back until it reaches OVERLAP before the cursor (or INITIAL back on the first
  #   poll), records everything oldest-first, and only then moves the cursor. A failure anywhere
  #   leaves the cursor where the last success put it, so the next poll reads the same listens
  #   again (the recorder recognises them by `source_event_id`) and carries on: an outage of any
  #   length is recovered by paging back to the cursor, never bounded by the overlap.
  # - The overlap exists for scrobblers that submit late (an offline phone): those listens carry an
  #   earlier `listened_at` than the cursor and are caught on the next poll.
  # - MAX_PAGES bounds one poll; when it is hit before the cursor is reached, what was read is
  #   recorded and the cursor stays, so the next poll continues from the newest listens again.
  # - Failures: 429 waits for Retry-After (the shared pacer pauses everyone); a 404 means the
  #   ListenBrainz account is gone or renamed (`needs_reauth`: connect again); 5xx and network back
  #   off 1, 2, 4… up to 60 minutes.
  #
  # Listens are stored only while LISTENBRAINZ_INGESTION_ENABLED is on (ListeningStorage).
  class Poller
    PAGE = 100
    MAX_PAGES = 100
    OVERLAP = 24.hours
    INITIAL = 30.days
    MAX_BACKOFF = 60.minutes
    LOCK = "listenbrainz-poll:%d".freeze

    Result = Data.define(:status, :poll)

    def initialize(client: Client.new, clock: -> { Time.current }, recorder: Listening::Recorder)
      @client = client
      @clock = clock
      @recorder = recorder
    end

    def poll!(source, trigger: "schedule", force: false)
      return Result.new(status: :skipped, poll: nil) unless ListeningStorage.enabled?("listenbrainz")

      with_lock(source) do
        source.reload
        next Result.new(status: :skipped, poll: nil) unless source.connected? && !source.paused?
        next Result.new(status: :waiting, poll: nil) if !force && source.next_poll_at && source.next_poll_at > now

        run(source, trigger)
      end || Result.new(status: :busy, poll: nil)
    end

    private

    def now = @clock.call

    def with_lock(source)
      key = format(LOCK, source.id)
      ApplicationRecord.connection_pool.with_connection do |conn|
        locked = conn.select_value(ApplicationRecord.sanitize_sql_array([ "SELECT pg_try_advisory_lock(hashtext(?))", key ]))
        return nil unless locked

        begin
          yield
        ensure
          conn.select_value(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_unlock(hashtext(?))", key ]))
        end
      end
    end

    def run(source, trigger)
      poll = ListeningPoll.create!(listening_source: source, user_id: source.user_id, trigger: trigger, started_at: now)
      floor = source.high_water_at ? source.high_water_at - OVERLAP : now - INITIAL
      items, reached = fetch(source, poll, floor)
      events = []
      malformed = items.count do |item|
        events << Mapping.event(item)
        false
      rescue Mapping::Malformed
        true
      end
      tally = @recorder.new(source, now: @clock).record_all!(events)
      finish_ok!(source, poll, tally, events, reached, malformed, floor)
      Result.new(status: :ok, poll: poll)
    rescue Error::RateLimited => e
      fail!(source, poll, "rate_limited", e.message, wait: e.retry_after.seconds, retry_after: e.retry_after)
    rescue Error::NotFound => e
      source.update!(state: "needs_reauth")
      fail!(source, poll, "needs_reauth", "ListenBrainz has no account #{source.external_account_id} any more: #{e.message}", wait: nil)
    rescue Error, ListeningStorage::DisabledError => e
      fail!(source, poll, "unavailable", e.message, wait: backoff(source))
    rescue StandardError => e
      fail!(source, poll, "failed", "#{e.class.name}: #{e.message}", wait: backoff(source))
      raise
    end

    # Newest first, paging back with `max_ts` until a listen at or before `floor` is seen, the
    # page runs short, or MAX_PAGES. Returns the listens newer than `floor` and whether the floor
    # was reached.
    def fetch(source, poll, floor)
      items = []
      max_ts = nil
      MAX_PAGES.times do
        page = @client.listens(source.external_account_id, max_ts: max_ts, count: PAGE)
        poll.increment(:pages)
        poll.increment(:http_requests)
        newer = page.select { |l| l["listened_at"].to_i > floor.to_i }
        if page.empty? || newer.size < page.size || page.size < PAGE
          items.concat(newer)
          return [ items, true ]
        end

        # A full page's oldest second is left for the next page (which starts one second after it),
        # so listens sharing that second across the boundary are neither lost nor read twice.
        boundary = page.map { |l| l["listened_at"].to_i }.min
        kept = newer.reject { |l| l["listened_at"].to_i == boundary }
        items.concat(kept.empty? ? newer : kept)
        max_ts = kept.empty? ? boundary : boundary + 1
      end
      [ items, false ]
    end

    def finish_ok!(source, poll, tally, events, reached, malformed, floor)
      oldest, newest = events.map(&:reported_at).minmax
      created = tally.fetch(:created, 0)
      ApplicationRecord.transaction do
        poll.update!(finished_at: now, outcome: "ok", items: events.size + malformed, malformed: malformed, recorded: tally,
                     oldest_reported_at: oldest, newest_reported_at: newest, reached_known: reached)
        source.update!(last_poll_at: now, last_success_at: now, next_poll_at: nil, consecutive_failures: 0, last_error: nil, last_error_at: nil,
                       plays_added: source.plays_added + created, last_new_play_at: created.positive? ? now : source.last_new_play_at,
                       covered_from: [ source.covered_from, (reached ? floor : nil), oldest ].compact.min,
                       # The cursor moves only once everything back to the floor was recorded.
                       high_water_at: reached ? [ source.high_water_at, newest ].compact.max : source.high_water_at)
      end
      Rails.logger.warn("ListenBrainz poll for source #{source.id} hit MAX_PAGES before its cursor; it continues next time") unless reached
    end

    def fail!(source, poll, outcome, message, wait:, retry_after: nil)
      ApplicationRecord.transaction do
        poll&.update!(finished_at: now, outcome: outcome, error: message.to_s.truncate(500), retry_after: retry_after)
        source.reload.update!(last_poll_at: now, consecutive_failures: source.consecutive_failures + 1, last_error: message.to_s.truncate(500),
                              last_error_at: now, next_poll_at: wait && now + wait)
      end
      Result.new(status: outcome.to_sym, poll: poll)
    end

    def backoff(source) = [ (2**source.consecutive_failures).minutes, MAX_BACKOFF ].min
  end
end
