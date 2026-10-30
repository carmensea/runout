# One step of a user's history import (HistoryImport::Orchestrator). Each step enqueues the next.
class ImportRunJob < ApplicationJob
  queue_as :lastfm

  # One step per user at a time, across processes. A duplicate waits, then stops at once because
  # its token is stale. `duration` comfortably exceeds the longest step.
  limits_concurrency to: 1, key: ->(run_id, _token) { "import-user-#{ImportRun.where(id: run_id).pick(:user_id) || run_id}" },
                     duration: 15.minutes

  before_enqueue { HistoryImport.ensure_enabled! }

  # Storage was switched off while this job waited or ran: stop quietly, write nothing more. The
  # watchdog restarts the run once storage is enabled again.
  rescue_from HistoryImport::DisabledError do |error|
    Rails.logger.warn("ImportRunJob stopped: #{error.message}")
  end

  # Uncached: other processes change the run and its windows between this step's reads, and their
  # writes don't clear this thread's query cache.
  def perform(run_id, token)
    ImportRun.uncached { HistoryImport::Orchestrator.new.step!(run_id, token) }
  end
end
