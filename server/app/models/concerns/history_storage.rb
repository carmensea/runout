# Models that hold listening history or data derived from it. Rows can only be created while the
# writing source's storage is enabled (ListeningStorage: LASTFM_HISTORY_STORAGE_ENABLED for Last.fm,
# SPOTIFY_INGESTION_ENABLED inside a Spotify write), so nothing can persist real history by accident.
#
# Bulk inserts (insert_all, upsert_all and friends) skip model callbacks, so they are guarded
# separately.
module HistoryStorage
  extend ActiveSupport::Concern

  BULK_WRITES = %i[insert insert! insert_all insert_all! upsert upsert_all].freeze

  included do
    before_create { ListeningStorage.ensure_writable! }
  end

  class_methods do
    BULK_WRITES.each do |method|
      define_method(method) do |*args, **options, &block|
        ListeningStorage.ensure_writable!
        super(*args, **options, &block)
      end
    end
  end
end
