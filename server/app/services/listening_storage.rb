# Which source may write listening history right now (docs/spotify-plan.md §2;
# docs/long-term-architecture.md §9 #1). Last.fm history is gated by LASTFM_HISTORY_STORAGE_ENABLED
# (HistoryImport), Spotify's by SPOTIFY_INGESTION_ENABLED, the Last.fm loved list by
# LASTFM_LOVED_IMPORT_ENABLED (`lastfm_loved`): each source has its own switch, so
# directly scrobbled plays never depend on Last.fm's terms, and turning Spotify on never lets
# Last.fm history in.
#
# A Spotify write runs inside `writing_for("spotify") { ... }`; models with HistoryStorage and the
# catalogue matcher check `ensure_writable!` before creating anything.
module ListeningStorage
  class DisabledError < StandardError; end

  ENABLED_VALUES = %w[true 1].freeze
  KEY = :runout_listening_source

  module_function

  def enabled?(provider)
    case provider.to_s
    when "lastfm" then HistoryImport.enabled?
    when "spotify" then ENABLED_VALUES.include?(Rails.configuration.x.spotify_ingestion_enabled.to_s.strip.downcase)
    when "lastfm_loved" then ENABLED_VALUES.include?(Rails.configuration.x.lastfm_loved_import_enabled.to_s.strip.downcase)
    else false
    end
  end

  def current = ActiveSupport::IsolatedExecutionState[KEY]

  # Runs the block as a write by `provider`, which must be switched on.
  def writing_for(provider)
    provider = provider.to_s
    raise DisabledError, "Storing #{provider} listening history is disabled" unless enabled?(provider)

    previous = current
    begin
      ActiveSupport::IsolatedExecutionState[KEY] = provider
      yield
    ensure
      ActiveSupport::IsolatedExecutionState[KEY] = previous
    end
  end

  def writable? = HistoryImport.enabled? || (current.present? && enabled?(current))

  def ensure_writable!
    return if writable?
    raise HistoryImport::DisabledError if current.nil?

    raise DisabledError, "Storing #{current} listening history is disabled"
  end
end
