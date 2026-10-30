# Scheduled recovery (config/recurring.yml): expired leases, abandoned staging, stalled runs.
class ImportWatchdogJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: "import-watchdog", duration: 10.minutes, on_conflict: :discard

  def perform
    result = HistoryImport::Recovery.new.run!
    Rails.logger.info("ImportWatchdogJob: #{result.to_json}") if result.values.any? { |v| v.is_a?(Hash) ? v.any? : v.positive? }
  end
end
