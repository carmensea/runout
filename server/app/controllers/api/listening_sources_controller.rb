module Api
  # Listening sources in Settings (docs/spotify-plan.md §7–8). Never returns credentials.
  class ListeningSourcesController < ApplicationController
    require_authentication

    def index
      render json: Listening::SourceStatus.for(Current.user)
    end

    def disconnect
      source = Current.user.listening_sources.spotify.where.not(state: "disconnected").order(:id).last
      return render(json: { error: "not_connected" }, status: :not_found) unless source

      Spotify::Account.new.disconnect!(source)
      render json: Listening::SourceStatus.for(Current.user)
    end
  end
end
