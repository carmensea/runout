# Gate for storing Last.fm listening history (docs/milestone-2-plan.md §2).
#
# Off in every environment unless LASTFM_HISTORY_STORAGE_ENABLED is exactly "true" or "1", and it
# stays off until Last.fm's storage terms are resolved. Read-only verification (lastfm:probe) and
# synthetic tests don't need it; anything that persists fetched history must call ensure_enabled!.
module HistoryImport
  class DisabledError < StandardError
    def initialize(msg = "Storing Last.fm listening history is disabled (LASTFM_HISTORY_STORAGE_ENABLED).")
      super
    end
  end

  ENABLED_VALUES = %w[true 1].freeze

  module_function

  def enabled?
    ENABLED_VALUES.include?(Rails.configuration.x.history_import_enabled.to_s.strip.downcase)
  end

  def ensure_enabled!
    raise DisabledError unless enabled?
  end
end
