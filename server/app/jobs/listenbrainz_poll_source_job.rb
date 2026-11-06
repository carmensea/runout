# One poll of one ListenBrainz account (Listenbrainz::Poller). At most one per account at a time.
class ListenbrainzPollSourceJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(source_id, **) { "listenbrainz-poll-#{source_id}" }, duration: 10.minutes, on_conflict: :discard

  def perform(source_id, trigger: "schedule", force: false)
    source = ListeningSource.where(provider: "listenbrainz").find_by(id: source_id) or return
    result = Listenbrainz::Poller.new.poll!(source, trigger: trigger, force: force)
    Rails.logger.info("ListenbrainzPollSourceJob #{source_id}: #{result.status} #{result.poll&.recorded.to_json}")
  end
end
