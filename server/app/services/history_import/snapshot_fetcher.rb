module HistoryImport
  # Reads one complete window from Last.fm, every page, without touching the database. Raises
  # Inconsistent when the pages don't add up to one coherent result (plays added or removed while
  # paging), so the caller can try again.
  class SnapshotFetcher
    PAGE_SIZE = 200

    # The window's results shifted between pages, or the rows don't match the reported counts.
    class Inconsistent < StandardError; end
    # This validation used up its request allowance (docs/milestone-2-plan.md §7.3).
    class BudgetExceeded < StandardError; end
    # The window has more pages than allowed; raised right after page 1, before reading the rest.
    class TooLarge < StandardError
      attr_reader :total_pages

      def initialize(total_pages)
        @total_pages = total_pages
        super("window has #{total_pages} pages")
      end
    end

    Result = Data.define(:snapshot, :first_page)

    def initialize(client:, username:, session_key: nil, budget: nil, max_pages: nil)
      @client = client
      @username = username
      @session_key = session_key
      @budget = budget
      @max_pages = max_pages
    end

    # `budget` is shared by every snapshot of one validation; nil means unlimited.
    def fetch(range)
      first = page(range, 1)
      @budget&.size_for(first.total_pages)
      raise TooLarge, first.total_pages.to_i if @max_pages && first.total_pages.to_i > @max_pages

      pages = [ first ]
      (2..first.total_pages.to_i).each { |n| pages << page(range, n) }

      check_consistent!(pages, first)
      in_window, outside = pages.flat_map(&:scrobbles).partition { |s| range.cover?(s.played_at) }
      snapshot = Snapshot.new(
        entries: in_window.map { |s| Snapshot::Entry.from(s) },
        reported_total: first.total.to_i,
        total_pages: first.total_pages.to_i,
        undated_count: pages.sum(&:undated_count),
        malformed_count: pages.sum(&:malformed_count),
        out_of_window_count: outside.size
      )
      Result.new(snapshot: snapshot, first_page: first)
    end

    private

    def page(range, number)
      raise BudgetExceeded, "request budget for this window is used up" if @budget && @budget.exhausted?(@client.http_requests)

      @client.recent_tracks(username: @username, page: number, limit: PAGE_SIZE, from: range.begin, to: range.end,
                            session_key: @session_key)
    end

    # Every page must report the same total and page count, every full page must be full, and
    # all rows (dated, undated and malformed) must add up to the reported total.
    def check_consistent!(pages, first)
      pages.each_with_index do |p, i|
        if p.total != first.total || p.total_pages != first.total_pages
          raise Inconsistent, "page #{i + 1} reported #{p.total} plays in #{p.total_pages} pages; page 1 reported #{first.total} in #{first.total_pages}"
        end
      end

      counted = pages.sum { |p| p.scrobbles.size + p.undated_count + p.malformed_count }
      return if counted == first.total.to_i

      raise Inconsistent, "pages held #{counted} rows but Last.fm reported #{first.total}"
    end
  end
end
