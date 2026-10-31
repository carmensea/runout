# Enriches due metadata targets a batch at a time, then queues itself again while more are due
# (docs/milestone-4-plan.md §5). Recurring ticks start it; with METADATA_ENRICHMENT_ENABLED off, or
# nothing due, it does nothing. Only queued targets are fetched: nothing refetches the catalogue on
# its own, and new targets are queued deliberately (`enrich:plan`).
class MetadataEnrichJob < ApplicationJob
  queue_as :default
  BATCH = 25

  limits_concurrency to: 1, key: "metadata-enrich", duration: 30.minutes, on_conflict: :discard

  def perform
    return unless Metadata::Enrichment.enabled?
    return unless MetadataTarget.due.exists?

    artists = Metadata::Enricher.new.run!(limit: BATCH)
    artwork = Metadata::Artwork::Enricher.new.run!(limit: BATCH)
    Rails.logger.info("MetadataEnrichJob: artists #{artists.to_h.to_json}, artwork #{artwork.to_h.to_json}")
    self.class.perform_later if (artists.processed == BATCH || artwork.processed == BATCH) && MetadataTarget.due.exists?
  end
end
