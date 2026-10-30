# Matches newly committed name variants to the catalogue (Catalogue::Matcher), in bounded batches.
# Separate from importing: it reads only stored strings and never calls MusicBrainz or Last.fm.
class CatalogueMatchJob < ApplicationJob
  queue_as :default

  BATCH = 2_000

  # One at a time. Requests made meanwhile wait rather than being discarded: Solid Queue holds the
  # concurrency slot for the whole run, so discarding would drop every request made while a match
  # was running, including this job's own continuation (found by the Solid Queue smoke test). A
  # queued request that finds nothing left to match finishes at once.
  limits_concurrency to: 1, key: "catalogue-match", duration: 30.minutes

  before_enqueue { HistoryImport.ensure_enabled! }
  rescue_from(HistoryImport::DisabledError) { |error| Rails.logger.warn("CatalogueMatchJob stopped: #{error.message}") }

  def perform
    matched = Catalogue::Matcher.new.match_pending!(limit: BATCH)
    self.class.perform_later if matched == BATCH
  end
end
