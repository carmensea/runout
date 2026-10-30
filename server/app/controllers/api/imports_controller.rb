module Api
  # The full import (docs/milestone-2-plan.md §15.1): status, start, pause, resume, cancel, and
  # retrying a stopped period. Cancel is offered for the full import only; synchronisation has its
  # own pause (SyncsController).
  class ImportsController < ApplicationController
    include HistoryControls

    before_action :require_storage!, except: :show

    def show
      render json: HistoryImport::ImportStatus.for(Current.user)
    end

    def create
      active = ImportRun.active.find_by(user: Current.user)
      return render json: { error: "busy" }, status: :conflict if active && active.kind != "full"

      run = orchestrator.start!(Current.user)
      render json: { started: active.nil?, already: active.present?, runId: run.id }, status: active ? :ok : :accepted
    end

    def pause
      run = full_run(%w[planning running needs_review]) or return not_active
      render json: { paused: orchestrator.pause!(run) }
    end

    def resume
      run = full_run(%w[paused needs_review]) or return not_active
      orchestrator.resume!(run)
      render json: { resumed: true }
    end

    def cancel
      return render json: { error: "confirmation_required" }, status: :unprocessable_content unless confirmed?

      run = full_run(ImportRun::ACTIVE_STATES) or return not_active
      orchestrator.cancel!(run)
      render json: { cancelled: true }
    end

    # Fetches a stopped period again from scratch. A sync picks it up if no run is active.
    def retry_period
      window = ImportWindow.live.where(user_id: Current.user.id).find(params[:id])
      return render json: { error: "not_stopped" }, status: :conflict unless window.stopped?

      HistoryImport::Recovery.new.retry_window!(window)
      begin
        HistoryImport::Sync.start!(Current.user, kind: "sync") unless ImportRun.active.exists?(user_id: Current.user.id)
      rescue HistoryImport::Sync::Busy, HistoryImport::Sync::NotEligible
        nil # the next due sync picks it up
      end
      render json: { retried: true }
    end

    private

    def orchestrator = HistoryImport::Orchestrator.new

    def full_run(states) = ImportRun.where(user: Current.user, kind: "full", state: states).order(:created_at).last

    def not_active = render(json: { error: "not_active" }, status: :conflict)
  end
end
