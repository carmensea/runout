module Metadata
  # Enrichment fetches public metadata (MusicBrainz) about catalogue entities. It never reads or
  # writes listening history beyond counting plays to set priorities, and never changes the catalogue:
  # matching and enrichment are separate. Off unless METADATA_ENRICHMENT_ENABLED is set; independent
  # of LASTFM_HISTORY_STORAGE_ENABLED.
  module Enrichment
    PROVIDER = "musicbrainz".freeze
    CORE_LICENSE = "CC0-1.0".freeze
    SUPPLEMENTARY_LICENSE = "CC-BY-NC-SA-3.0".freeze

    class Disabled < StandardError; end

    module_function

    def enabled? = %w[1 true yes on].include?(Rails.configuration.x.metadata_enrichment_enabled.to_s.strip.downcase)

    def ensure_enabled!
      raise Disabled, "Metadata enrichment is off (METADATA_ENRICHMENT_ENABLED)" unless enabled?
    end
  end
end
