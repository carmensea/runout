module Api
  # GET /api/sync: synchronisation health for the signed-in user (HistoryImport::SyncHealth).
  # Read-only; works with history storage off too (it then reports nothing scheduled).
  class SyncsController < ApplicationController
    require_authentication

    def show
      render json: HistoryImport::SyncHealth.for(Current.user)
    end
  end
end
