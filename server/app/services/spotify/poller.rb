module Spotify
  # One poll of a connected Spotify account (docs/spotify-plan.md §10): reads Recently Played and
  # records every completed play through Listening::Recorder. Safe to run any number of times,
  # concurrently or after a crash:
  #
  # - One poll per source at a time: a session-level advisory lock, taken without waiting; a poll
  #   that can't take it does nothing (`:busy`).
  # - Overlapping on purpose: every poll reads the newest plays, so plays seen before are read
  #   again and recognised (same event ID), never added twice. When the newest page doesn't reach
  #   back to the newest play already recorded, it pages back with Spotify's `before` cursor, up to
  #   MAX_PAGES.
  # - Gaps: if it still doesn't reach a play recorded before, plays between the newest one recorded
  #   and the oldest one returned may be lost (Spotify keeps only its most recent plays): that
  #   interval becomes a ListeningGap. If Spotify returns nothing at all although plays were
  #   recorded before, the gap runs to now. Nothing is invented for a gap.
  # - Failures change nothing recorded. 429 waits for Retry-After; network and 5xx back off
  #   (1, 2, 4… up to 60 minutes); 403 waits an hour; a refused refresh token stops polling until
  #   the account is connected again. Times are kept on the source, so a restart resumes.
  #
  # Plays are stored only while Spotify ingestion is switched on (ListeningStorage).
  class Poller
    PAGE = 50
    MAX_PAGES = 4
    MAX_BACKOFF = 60.minutes
    FORBIDDEN_WAIT = 1.hour
    LOCK = "spotify-poll:%d".freeze

    Result = Data.define(:status, :poll) # status: :ok, :busy, :skipped, :waiting, or the failure outcome

    def initialize(account: Account.new, clock: -> { Time.current }, recorder: Listening::Recorder)
      @account = account
      @clock = clock
      @recorder = recorder
    end

    # `force`: ignore the backoff time, except Spotify's own Retry-After.
    def poll!(source, trigger: "schedule", force: false)
      return Result.new(status: :skipped, poll: nil) unless ListeningStorage.enabled?("spotify")

      with_lock(source) do
        source.reload
        next Result.new(status: :skipped, poll: nil) unless source.connected? && !source.paused?
        next Result.new(status: :waiting, poll: nil) if waiting?(source, force)

        run(source, trigger)
      end || Result.new(status: :busy, poll: nil)
    end

    private

    def now = @clock.call

    def waiting?(source, force)
      return false unless source.next_poll_at && source.next_poll_at > now

      !force || source.last_error.to_s.start_with?("rate limited")
    end

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
      requests_before = @account.client.requests
      items = fetch(source, poll)
      events = []
      malformed = items.count do |item|
        events << Mapping.event(item)
        false
      rescue Mapping::Malformed
        true
      end
      known = source.high_water_at
      oldest, newest = events.map(&:reported_at).minmax
      reached = known.nil? || (!oldest.nil? && oldest <= known)
      tally = @recorder.new(source, now: @clock).record_all!(events)
      finish_ok!(source, poll, tally, oldest, newest, reached, malformed, requests_before, items.size)
      Result.new(status: :ok, poll: poll)
    rescue Error::RateLimited => e
      fail!(source, poll, "rate_limited", "rate limited by Spotify#{" (#{e.reason})" if e.reason}", wait: e.retry_after.seconds, retry_after: e.retry_after,
                                                                                             requests_before: requests_before)
    rescue Error::Forbidden => e
      fail!(source, poll, "forbidden", e.message, wait: FORBIDDEN_WAIT, requests_before: requests_before)
    rescue Account::NotConnected => e
      fail!(source, poll, "needs_reauth", e.message, wait: nil, requests_before: requests_before)
    rescue Error, ListeningStorage::DisabledError => e
      fail!(source, poll, "unavailable", e.message, wait: backoff(source), requests_before: requests_before)
    rescue StandardError => e
      # Unexpected: recorded and backed off like an outage, then raised so the job shows it.
      fail!(source, poll, "failed", "#{e.class.name}: #{e.message}", wait: backoff(source), requests_before: requests_before)
      raise
    end

    # Newest first; pages back until a play recorded before is reached, Spotify has no more, or
    # MAX_PAGES.
    def fetch(source, poll)
      items = []
      cursor = nil
      MAX_PAGES.times do
        data = @account.with_token(source) { |token| @account.client.recently_played(token, limit: PAGE, before: cursor) }
        page = Array(data["items"])
        poll.increment(:pages)
        items.concat(page)
        cursor = data.dig("cursors", "before")
        break if page.size < PAGE || cursor.blank? || reached_known?(page, source.high_water_at)
      end
      items
    end

    def reached_known?(page, known)
      return true if known.nil?

      page.any? { |item| (Time.iso8601(item["played_at"].to_s) rescue nil)&.<=(known) }
    end

    def finish_ok!(source, poll, tally, oldest, newest, reached, malformed, requests_before, item_count)
      gap = nil
      ApplicationRecord.transaction do
        poll.update!(finished_at: now, outcome: "ok", http_requests: @account.client.requests - requests_before, items: item_count,
                     malformed: malformed, recorded: tally, oldest_reported_at: oldest, newest_reported_at: newest, reached_known: reached)
        if !reached && source.high_water_at < (oldest || now)
          gap = ListeningGap.create!(listening_source: source, user_id: source.user_id, gap_from: source.high_water_at, gap_to: oldest || now,
                                     listening_poll: poll, detected_at: now)
        end
        created = tally.fetch(:created, 0)
        source.update!(last_poll_at: now, last_success_at: now, next_poll_at: nil, consecutive_failures: 0, last_error: nil, last_error_at: nil,
                       high_water_at: [ source.high_water_at, newest ].compact.max, covered_from: source.covered_from || oldest || now,
                       plays_added: source.plays_added + created, last_new_play_at: created.positive? ? now : source.last_new_play_at)
      end
      Rails.logger.warn("Spotify poll found a possible gap for source #{source.id}: #{gap.gap_from.iso8601} to #{gap.gap_to.iso8601}") if gap
    end

    def fail!(source, poll, outcome, message, wait:, requests_before:, retry_after: nil)
      ApplicationRecord.transaction do
        poll&.update!(finished_at: now, outcome: outcome, error: message.to_s.truncate(500), retry_after: retry_after,
                      http_requests: @account.client.requests - requests_before.to_i)
        source.reload.update!(last_poll_at: now, consecutive_failures: source.consecutive_failures + 1, last_error: message.to_s.truncate(500),
                              last_error_at: now, next_poll_at: wait && now + wait)
      end
      Result.new(status: outcome.to_sym, poll: poll)
    end

    def backoff(source) = [ (2**source.consecutive_failures).minutes, MAX_BACKOFF ].min
  end
end
