# Artwork from ListenBrainz's mapping for every ListenBrainz user (Metadata::InferredArtwork):
# candidates are rewritten from their observations, then a bounded batch is checked and fetched.
# Does nothing while METADATA_ENRICHMENT_ENABLED is off.
class InferredArtworkJob < ApplicationJob
  queue_as :default
  BATCH = 25

  limits_concurrency to: 1, key: "inferred-artwork", duration: 30.minutes, on_conflict: :discard

  def perform
    return unless Metadata::Enrichment.enabled?

    User.where(id: ListeningObservation.where(provider: "listenbrainz").select(:user_id).distinct).find_each { |user| Metadata::InferredArtwork.plan!(user) }
    summary = Metadata::InferredArtwork::Enricher.new.run!(limit: BATCH)
    Rails.logger.info("InferredArtworkJob: #{summary.to_h.to_json}")
  end
end
