# Daily (config/recurring.yml): measures the plays present in every committed period, so the
# status endpoint can report count discrepancies without counting plays per request
# (HistoryImport::CountCheck). Does nothing while history storage is off.
class CountCheckJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: "count-check", duration: 1.hour, on_conflict: :discard

  def perform
    return unless HistoryImport.enabled?

    results = HistoryImport::CountCheck.run_all!
    mismatched = results.select { |_, r| r[:mismatched].positive? }
    Rails.logger.warn("CountCheckJob: count discrepancies #{mismatched.to_json}") if mismatched.any?
  end
end
