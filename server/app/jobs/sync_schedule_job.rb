# The recurring synchronisation tick (config/recurring.yml): starts whatever kind of sync is due
# for each eligible user (HistoryImport::Sync). It only enqueues runs; the work happens in their
# ImportRunJob chains. With history storage off it does nothing at all.
class SyncScheduleJob < ApplicationJob
  queue_as :default

  # One tick at a time; an overlapping one has nothing to add.
  limits_concurrency to: 1, key: "history-sync-tick", duration: 10.minutes, on_conflict: :discard

  def perform
    return Rails.logger.info("SyncScheduleJob: history storage is off; nothing scheduled") unless HistoryImport.enabled?

    started = HistoryImport::Sync.tick!.select { |_, outcome| HistoryImport::Sync::KINDS.include?(outcome) }
    Rails.logger.info("SyncScheduleJob: started #{started.to_json}") if started.any?
  end
end
