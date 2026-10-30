# Matches newly committed name variants to the catalogue (Catalogue::Matcher), in bounded batches.
# Separate from importing: it reads only stored strings and never calls MusicBrainz or Last.fm.
class CatalogueMatchJob < ApplicationJob
  queue_as :default

  BATCH = 2_000

  # Matching is idempotent, so a second request while one is queued or running adds nothing.
  limits_concurrency to: 1, key: "catalogue-match", duration: 30.minutes, on_conflict: :discard

  before_enqueue { HistoryImport.ensure_enabled! }
  rescue_from(HistoryImport::DisabledError) { |error| Rails.logger.warn("CatalogueMatchJob stopped: #{error.message}") }

  def perform
    matched = Catalogue::Matcher.new.match_pending!(limit: BATCH)
    self.class.perform_later if matched == BATCH
  end
end
