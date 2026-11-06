module Listenbrainz
  # The rest of a connected account's history, once the first poll has taken the last 30 days
  # (docs/listenbrainz-spotify-feasibility.md §4.4). Reads the public listens endpoint backwards
  # from `covered_from` in pages of PAGE and records each page before moving the cursor
  # (`backfill_before`): a run does at most `pages` pages and the next tick continues, so a run
  # that stops anywhere (outage, rate limit, deploy) resumes at the last recorded page, and the
  # recorder recognises anything read twice (same `source_event_id`). A full page's oldest second
  # is left for the next page (the cursor sits one second after it), so listens sharing that second
  # across the page boundary are neither lost nor read twice. Done when ListenBrainz returns a
  # short page. `backfill_total` is
  # ListenBrainz's listen count at the start, for progress; `backfill_fetched` counts listens read.
  #
  # No token: the export API would need one kept on file (the plan's §4.4), while the listens
  # endpoint serves the same listens with the same metadata, one request a second, from the
  # account's public history. Runs only while LISTENBRAINZ_INGESTION_ENABLED is on.
  class Backfill
    PAGE = 1000 # ListenBrainz's maximum
    PAGES_PER_RUN = 5
    LOCK = "listenbrainz-backfill:%d".freeze

    Result = Data.define(:status, :poll) # :done, :partial, :skipped, :busy, or the failure outcome

    def initialize(client: Client.new, clock: -> { Time.current }, recorder: Listening::Recorder, page: PAGE)
      @client = client
      @clock = clock
      @recorder = recorder
      @page = page
    end

    def run!(source, pages: PAGES_PER_RUN, trigger: "backfill")
      return Result.new(status: :skipped, poll: nil) unless ListeningStorage.enabled?("listenbrainz")

      with_lock(source) do
        source.reload
        next Result.new(status: :skipped, poll: nil) unless source.connected? && !source.paused? && source.covered_from && source.backfill_state != "done"

        run(source, pages, trigger)
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

    def run(source, pages, trigger)
      poll = ListeningPoll.create!(listening_source: source, user_id: source.user_id, trigger: trigger, started_at: now)
      start!(source, poll) unless source.backfill_state
      status = :partial
      pages.times do
        page = @client.listens(source.external_account_id, max_ts: source.backfill_before.to_i, count: @page)
        poll.increment!(:pages)
        poll.increment!(:http_requests)
        record_page!(source, poll, page)
        if page.size < @page
          source.update!(backfill_state: "done", backfill_finished_at: now)
          status = :done
          break
        end
      end
      poll.update!(finished_at: now, outcome: "ok")
      Result.new(status: status, poll: poll)
    rescue Error::RateLimited => e
      fail!(source, poll, "rate_limited", e.message, retry_after: e.retry_after)
    rescue Error::NotFound => e
      source.update!(state: "needs_reauth")
      fail!(source, poll, "needs_reauth", "ListenBrainz has no account #{source.external_account_id} any more: #{e.message}")
    rescue Error, ListeningStorage::DisabledError => e
      fail!(source, poll, "unavailable", e.message)
    rescue StandardError => e
      fail!(source, poll, "failed", "#{e.class.name}: #{e.message}")
      raise
    end

    def start!(source, poll)
      total = @client.listen_count(source.external_account_id)
      poll.increment!(:http_requests)
      source.update!(backfill_state: "running", backfill_started_at: now, backfill_total: total, backfill_fetched: 0,
                     backfill_before: source.covered_from + 1.second)
    end

    # One page, oldest first through the recorder, then the cursor: a failure inside leaves the
    # cursor at the previous page.
    def record_page!(source, poll, page)
      page, before = split(page)
      events = []
      malformed = page.count do |item|
        events << Mapping.event(item)
        false
      rescue Mapping::Malformed
        true
      end
      tally = @recorder.new(source, now: @clock).record_all!(events)
      oldest = events.map(&:reported_at).min
      created = tally.fetch(:created, 0)
      ApplicationRecord.transaction do
        poll.update!(items: poll.items + page.size, malformed: poll.malformed + malformed, recorded: poll.recorded.merge(tally.stringify_keys) { |_, a, b| a + b },
                     oldest_reported_at: [ poll.oldest_reported_at, oldest ].compact.min, newest_reported_at: poll.newest_reported_at || events.map(&:reported_at).max)
        source.update!(backfill_fetched: source.backfill_fetched + page.size, backfill_before: before || source.backfill_before,
                       covered_from: [ source.covered_from, oldest ].compact.min, plays_added: source.plays_added + created,
                       last_new_play_at: created.positive? ? now : source.last_new_play_at)
      end
    end

    # A full page minus its oldest second, and the cursor just after that second: the next page
    # starts with those listens. A short page is the last; a page all in one second can't be split.
    def split(page)
      return [ page, nil ] if page.size < @page

      boundary = page.map { |l| l["listened_at"].to_i }.min
      kept = page.reject { |l| l["listened_at"].to_i == boundary }
      kept.empty? ? [ page, Time.at(boundary).utc ] : [ kept, Time.at(boundary + 1).utc ]
    end

    def fail!(source, poll, outcome, message, retry_after: nil)
      poll.update!(finished_at: now, outcome: outcome, error: message.to_s.truncate(500), retry_after: retry_after)
      source.update!(last_error: message.to_s.truncate(500), last_error_at: now)
      Result.new(status: outcome.to_sym, poll: poll)
    end
  end
end
