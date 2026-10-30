module HistoryImport
  # Replaces a window with two non-overlapping halves [from, mid) and [mid, to). The parent becomes
  # `split` first, so the no-overlap constraint holds at every step. Called inside the caller's
  # lease transaction.
  module WindowSplitter
    MIN_DURATION = 1.hour

    module_function

    def splittable?(window)
      (window.window_to - window.window_from) >= MIN_DURATION * 2
    end

    def split!(window)
      raise ArgumentError, "window #{window.id} is too small to split" unless splittable?(window)

      mid = Time.at(((window.window_from.to_i + window.window_to.to_i) / 2)).utc
      window.update!(state: "split", claim_token: nil, lease_expires_at: nil)
      [ [ window.window_from, mid ], [ mid, window.window_to ] ].map do |from, to|
        ImportWindow.create!(user_id: window.user_id, import_run_id: window.import_run_id, parent_window: window,
                             window_from: from, window_to: to, state: "pending")
      end
    end
  end
end
