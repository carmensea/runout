module Api
  # Synchronisation (docs/milestone-2-plan.md §15.1). GET answers 304 when nothing changed (ETag
  # from SyncHealth.version), so polling an idle archive costs one small query.
  class SyncsController < ApplicationController
    include HistoryControls

    # "Refresh now" at most this often; the recurring tick runs anyway.
    REFRESH_INTERVAL = 5.minutes

    before_action :require_storage!, except: :show

    def show
      return unless stale?(etag: [ Current.user.id, HistoryImport::SyncHealth.version(Current.user) ], public: false)

      render json: HistoryImport::SyncHealth.for(Current.user)
    end

    def refresh
      last = ImportRun.where(user: Current.user, kind: "sync").maximum(:started_at)
      if last && last > REFRESH_INTERVAL.ago
        return render json: { error: "too_soon", retryAfter: (last + REFRESH_INTERVAL).iso8601 }, status: :too_many_requests
      end

      run = HistoryImport::Sync.start!(Current.user, kind: "sync")
      render json: { started: true, runId: run.id }, status: :accepted
    rescue HistoryImport::Sync::Busy
      render json: { error: "busy" }, status: :conflict
    rescue HistoryImport::Sync::NotEligible => e
      render json: { error: "not_eligible", message: e.message }, status: :conflict
    end

    def pause
      paused = HistoryImport::Sync.pause!(Current.user)
      render json: { paused: true, already: !paused }
    end

    # Clears a pause, and allows synchronisation again after an account problem was fixed. The
    # next sync checks the account before fetching anything.
    def resume
      unpaused = HistoryImport::Sync.unpause!(Current.user)
      account = HistoryImport::Sync.resume!(Current.user)
      render json: { resumed: unpaused || account, already: !(unpaused || account) }
    end
  end
end
