# Models that hold Last.fm listening history or data derived from it. Rows can only be created while
# history storage is enabled (HistoryImport, LASTFM_HISTORY_STORAGE_ENABLED), so nothing can persist
# real history by accident before Last.fm's storage terms are resolved.
#
# Bulk inserts (insert_all, upsert_all and friends) skip model callbacks, so they are guarded
# separately.
module HistoryStorage
  extend ActiveSupport::Concern

  BULK_WRITES = %i[insert insert! insert_all insert_all! upsert upsert_all].freeze

  included do
    before_create { HistoryImport.ensure_enabled! }
  end

  class_methods do
    BULK_WRITES.each do |method|
      define_method(method) do |*args, **options, &block|
        HistoryImport.ensure_enabled!
        super(*args, **options, &block)
      end
    end
  end
end
