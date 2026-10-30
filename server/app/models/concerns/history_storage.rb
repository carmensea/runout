# Models that hold Last.fm listening history or data derived from it. Rows can only be created while
# history storage is enabled (HistoryImport, LASTFM_HISTORY_STORAGE_ENABLED), so nothing can persist
# real history by accident before Last.fm's storage terms are resolved.
module HistoryStorage
  extend ActiveSupport::Concern

  included do
    before_create { HistoryImport.ensure_enabled! }
  end
end
