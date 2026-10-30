module HistoryImport
  # Caps the outbound HTTP attempts for one window (docs/milestone-2-plan.md §7.3, "Combined retry
  # budget"). It counts the client's actual requests, so client retries count too, and it starts
  # from the window's persisted total, so validation restarts and job retries can't reset it.
  #
  # - Per run: 4 snapshots x (pages + 1), doubled for retries, at most MAX.
  # - Per window, over its lifetime: twice the per-run limit, at most TOTAL_MAX.
  class RequestBudget
    MAX = 200
    TOTAL_MAX = 400
    INITIAL = 10 # per run, before the first page reveals the size

    attr_reader :limit, :total_limit

    def initialize(client, previously_used: 0)
      @client = client
      @start = client.http_requests
      @previously_used = previously_used
      @limit = INITIAL
      @total_limit = TOTAL_MAX
    end

    def size_for(total_pages)
      @limit = [ [ WindowValidator::MAX_SNAPSHOTS * (total_pages.to_i + 1) * 2, INITIAL ].max, MAX ].min
      @total_limit = [ @limit * 2, TOTAL_MAX ].min
    end

    def used = @client.http_requests - @start
    def total_used = @previously_used + used
    def total_exhausted? = total_used >= @total_limit
    def exhausted?(_current = nil) = used >= @limit || total_exhausted?
  end
end
