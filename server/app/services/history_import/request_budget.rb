module HistoryImport
  # Caps the HTTP requests one window validation may make, retries included
  # (docs/milestone-2-plan.md §7.3, "Combined retry budget"). The limit is set once the window's
  # size is known: 4 snapshots x (pages + 1), doubled for retries, never above MAX.
  class RequestBudget
    MAX = 200
    INITIAL = 10 # before the first page reveals the size

    attr_reader :limit

    def initialize(client)
      @client = client
      @start = client.http_requests
      @limit = INITIAL
    end

    def size_for(total_pages)
      @limit = [ [ WindowValidator::MAX_SNAPSHOTS * (total_pages.to_i + 1) * 2, INITIAL ].max, MAX ].min
    end

    def used = @client.http_requests - @start

    def exhausted?(_current = nil) = used >= @limit
  end
end
