module Lastfm
  # Read-only verification of user.getRecentTracks behaviour (docs/milestone-2-plan.md §3, A1 to A7).
  #
  # - Persists nothing: every response is held in memory and discarded.
  # - Reports only booleans, counts and relative offsets: no track names and no absolute timestamps.
  # - Conservative: a hard request budget, a minimum interval between requests, and it stops at
  #   the first rate-limit error instead of retrying.
  class ApiProbe
    class BudgetExceeded < StandardError; end

    DEFAULT_BUDGET = 20
    DEFAULT_INTERVAL = 1.25 # seconds between requests

    def initialize(client:, username:, session_key: nil, budget: DEFAULT_BUDGET, interval: DEFAULT_INTERVAL,
                   sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @username = username
      @session_key = session_key
      @budget = budget
      @interval = interval
      @sleeper = sleeper
      @requests = 0
    end

    def run
      findings = { requests: 0, rate_limited: false }
      first = fetch(limit: 200)
      findings[:a1_counts] = counts(first)
      findings[:a4_now_playing] = { present_on_page_1: first.now_playing, undated_rows_on_page_1: first.undated_count }
      return finish(findings, "no scrobbles in this account") if first.total.to_i.zero?

      oldest_page = fetch(limit: 200, page: first.total_pages)
      findings[:a3_ordering] = ordering(first, oldest_page)
      findings[:a2_boundaries] = boundaries(oldest_page)
      findings[:pagination] = pagination(first)
      findings[:empty_range] = empty_range(oldest_page)
      findings[:a5_signed_matches_unsigned] = signed_matches_unsigned
      findings[:metadata] = metadata(first.scrobbles + oldest_page.scrobbles)
      finish(findings)
    rescue Error::RateLimited
      findings[:rate_limited] = true
      finish(findings, "stopped at the first rate-limit error (code 29) without retrying")
    rescue BudgetExceeded
      finish(findings, "request budget of #{@budget} reached")
    end

    private

    def finish(findings, note = nil)
      findings[:requests] = @requests
      findings[:a7_rate] = { requests: @requests, min_interval_seconds: @interval, rate_limited: findings[:rate_limited] }
      findings[:note] = note if note
      findings
    end

    def fetch(**params)
      raise BudgetExceeded if @requests >= @budget

      @sleeper.call(@interval) if @requests.positive?
      @requests += 1
      @client.recent_tracks(username: @username, **params)
    end

    # A1: is a total given, and do totalPages agree with it (limit 200, and limit 1)?
    def counts(page)
      single = fetch(limit: 1)
      {
        total_attribute_present: !page.total.nil?,
        total_pages_consistent_at_200: page.total_pages == (page.total.to_i / 200.0).ceil,
        total_pages_equals_total_at_limit_1: single.total_pages == single.total,
        total_unchanged_between_reads: single.total == page.total
      }
    end

    # A3: newest first within and across pages, and stable on a second read of a historical page.
    def ordering(first, oldest_page)
      again = fetch(limit: 200, page: oldest_page.page)
      {
        newest_first_within_pages: [ first, oldest_page ].all? { |p| non_increasing?(p.scrobbles) },
        historical_page_identical_on_second_read: again.scrobbles == oldest_page.scrobbles,
        same_second_plays_seen: same_second_groups(first.scrobbles + oldest_page.scrobbles)
      }
    end

    # A2: probe one historical play whose second is unique, so the answer is unambiguous.
    def boundaries(oldest_page)
      seconds = oldest_page.scrobbles.group_by { |s| s.played_at.to_i }
      target = seconds.find { |_, plays| plays.size == 1 }&.first
      return { tested: false, reason: "no play with a unique second on the oldest page" } unless target

      at = Time.at(target).utc
      from_at = fetch(limit: 200, from: at, to: at + 3600)
      to_at = fetch(limit: 200, from: at - 3600, to: at)
      both_at = fetch(limit: 200, from: at, to: at)
      includes = ->(page) { page.scrobbles.any? { |s| s.played_at.to_i == target } }
      {
        tested: true,
        from_is_inclusive: includes.(from_at),
        to_is_inclusive: includes.(to_at),
        from_equals_to_returns_the_play: includes.(both_at),
        total_matches_rows_in_one_page_range: [ from_at, to_at ].all? { |p| p.total_pages.to_i > 1 || p.total.to_i == p.scrobbles.size }
      }
    end

    # What happens past the last page, which decides how a pagination loop must stop.
    def pagination(first)
      beyond = fetch(limit: 200, page: first.total_pages + 1)
      {
        page_past_end_returns_rows: beyond.scrobbles.any?,
        page_past_end_reports_page: beyond.page,
        page_past_end_total_pages: beyond.total_pages
      }
    end

    # A range before the first scrobble: how emptiness is reported.
    def empty_range(oldest_page)
      oldest = oldest_page.scrobbles.map(&:played_at).min
      empty = fetch(limit: 200, from: oldest - 30.days, to: oldest - 1.day)
      { rows: empty.scrobbles.size, total: empty.total, total_pages: empty.total_pages }
    end

    # A5: does signing with the session key change what is returned?
    def signed_matches_unsigned
      return nil if @session_key.blank?

      unsigned = fetch(limit: 10)
      signed = fetch(limit: 10, session_key: @session_key)
      unsigned.total == signed.total && unsigned.scrobbles.first == signed.scrobbles.first
    end

    def metadata(scrobbles)
      return {} if scrobbles.empty?

      share = ->(attr) { (scrobbles.count { |s| s.public_send(attr) } / scrobbles.size.to_f).round(2) }
      {
        sampled_rows: scrobbles.size,
        share_with_artist_mbid: share.(:artist_mbid),
        share_with_track_mbid: share.(:track_mbid),
        share_with_album_mbid: share.(:album_mbid),
        share_with_album_name: (scrobbles.count { |s| s.album.present? } / scrobbles.size.to_f).round(2)
      }
    end

    def non_increasing?(scrobbles)
      scrobbles.each_cons(2).all? { |a, b| a.played_at >= b.played_at }
    end

    def same_second_groups(scrobbles)
      scrobbles.group_by { |s| s.played_at.to_i }.count { |_, plays| plays.size > 1 }
    end
  end
end
