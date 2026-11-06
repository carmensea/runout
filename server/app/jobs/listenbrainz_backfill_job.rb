# One bounded run of a ListenBrainz account's history backfill (Listenbrainz::Backfill); the tick
# queues another until it is done. At most one per account at a time.
class ListenbrainzBackfillJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(source_id, **) { "listenbrainz-backfill-#{source_id}" }, duration: 30.minutes, on_conflict: :discard

  def perform(source_id)
    source = ListeningSource.where(provider: "listenbrainz").find_by(id: source_id) or return
    result = Listenbrainz::Backfill.new.run!(source)
    Rails.logger.info("ListenbrainzBackfillJob #{source_id}: #{result.status} #{result.poll&.recorded.to_json}")
  end
end
