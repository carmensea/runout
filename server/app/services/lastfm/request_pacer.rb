module Lastfm
  # Global request pacing across every Rails process (Puma threads, Solid Queue workers).
  #
  # One row in api_request_slots holds the earliest time the next request may start. reserve!
  # atomically takes the next slot, one statement using the database clock so every process agrees,
  # and sleeps until it. cool_down! pushes the next slot out for everyone after a rate-limit signal.
  #
  # Don't call it inside a long database transaction: the slot row stays locked until that
  # transaction commits, which would serialise other processes behind it.
  class RequestPacer
    DEFAULT_INTERVAL = 1.0  # seconds between requests (docs/lastfm-api-findings.md, A7)
    MAX_WAIT = 120.0        # longer waits raise instead of blocking a worker

    RESERVE_SQL = <<~SQL.freeze
      INSERT INTO api_request_slots (key, next_slot_at, updated_at)
      VALUES (:key, clock_timestamp() + make_interval(secs => :interval), clock_timestamp())
      ON CONFLICT (key) DO UPDATE
        SET next_slot_at = GREATEST(api_request_slots.next_slot_at, clock_timestamp()) + make_interval(secs => :interval),
            updated_at = clock_timestamp()
      RETURNING EXTRACT(EPOCH FROM (next_slot_at - make_interval(secs => :interval) - clock_timestamp()))::float8 AS wait
    SQL

    COOL_DOWN_SQL = <<~SQL.freeze
      INSERT INTO api_request_slots (key, next_slot_at, updated_at)
      VALUES (:key, clock_timestamp() + make_interval(secs => :seconds), clock_timestamp())
      ON CONFLICT (key) DO UPDATE
        SET next_slot_at = GREATEST(api_request_slots.next_slot_at, clock_timestamp() + make_interval(secs => :seconds)),
            updated_at = clock_timestamp()
    SQL

    attr_reader :interval

    def initialize(key: "lastfm", interval: DEFAULT_INTERVAL, max_wait: MAX_WAIT, sleeper: ->(seconds) { sleep(seconds) })
      @key = key
      @interval = Float(interval)
      @max_wait = max_wait
      @sleeper = sleeper
    end

    # Blocks until this caller's slot. Returns the seconds waited.
    def reserve!
      wait = [ execute(RESERVE_SQL, interval: @interval).to_f, 0.0 ].max
      if wait > @max_wait
        raise Error::RateLimited.new("Last.fm requests are paused for another #{wait.ceil} s", retry_after: wait)
      end

      @sleeper.call(wait) if wait.positive?
      wait
    end

    # After a rate-limit signal: no process starts another request for `seconds`.
    def cool_down!(seconds)
      execute(COOL_DOWN_SQL, seconds: Float(seconds))
    end

    private

    # exec_query, not select_value: select_value goes through ActiveRecord's query cache, which
    # Rails enables for every request and job, so a repeated reservation would get the cached
    # "go now" answer and pacing would silently stop working.
    def execute(sql, **binds)
      ActiveRecord::Base.connection_pool.with_connection do |conn|
        conn.exec_query(ActiveRecord::Base.sanitize_sql_array([ sql, { key: @key, **binds } ]), "Lastfm::RequestPacer").rows.first&.first
      end
    end
  end
end
