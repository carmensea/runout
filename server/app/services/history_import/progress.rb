module HistoryImport
  # What the import has durably achieved (docs/milestone-2-plan.md §8.2), for the API and the
  # operator tasks. Counts come from committed windows only, never from downloaded or staged data.
  #
  # `complete` means every period from the first month to the cutoff is committed, judged by
  # coverage rather than counts. Last.fm's playcount keeps rising with new listening (and can change
  # for other reasons), so it is shown for context and never used to declare the import finished;
  # `percent` stays below 100 until coverage is complete.
  Progress = Data.define(:state, :complete, :coverage, :reported_playcount, :committed_scrobbles, :expected_scrobbles,
                         :percent, :windows, :current_period, :history_from, :cutoff_at, :last_committed_at,
                         :last_activity_at, :last_error) do
    # Window buckets: `pending` includes failed windows with a retry scheduled; `failed` are those
    # that stopped retrying; `review` awaits a person.
    def self.bucket(window)
      case window.state
      when "pending" then :pending
      when "failed" then window.retry_at ? :pending : :failed
      when "committed" then :committed
      when "needs_review" then :review
      else :processing
      end
    end

    def self.for(user)
      run = ImportRun.where(user: user).order(:created_at).last
      windows = ImportWindow.live.where(user: user)
      buckets = windows.select(:state, :retry_at).group_by { |w| bucket(w) }.transform_values(&:size)
      committed = windows.committed.sum(:committed_count)
      # Last.fm's reported totals for the periods read so far; unread periods are unknown.
      expected = windows.where(state: %w[validated committing committed]).sum(:expected_total)
      coverage = run&.history_from && run.cutoff_at ? ImportCoverage.status_for(user, run.history_from, run.cutoff_at) : :missing
      complete = coverage == :complete && (buckets.keys - [ :committed ]).empty?
      current = run&.current_window_id && ImportWindow.find_by(id: run.current_window_id)

      new(state: run&.state || "not_started", complete: complete, coverage: coverage,
          reported_playcount: run&.reported_playcount, committed_scrobbles: committed, expected_scrobbles: expected,
          percent: percent(committed, run&.reported_playcount, complete),
          windows: { pending: 0, processing: 0, committed: 0, failed: 0, review: 0 }.merge(buckets),
          current_period: current && (current.window_from...current.window_to),
          history_from: run&.history_from, cutoff_at: run&.cutoff_at, last_committed_at: run&.last_committed_at,
          last_activity_at: run&.last_activity_at, last_error: run&.last_error)
    end

    def self.percent(committed, reported, complete)
      return 100 if complete
      return nil unless reported&.positive?

      [ (committed * 100 / reported), 99 ].min
    end
  end
end
