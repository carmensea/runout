module Api
  # Listening sources in Settings (docs/spotify-plan.md §7, §10). Never returns credentials.
  class ListeningSourcesController < ApplicationController
    # "Sync now" at most this often; the recurring tick runs anyway.
    SYNC_INTERVAL = 1.minute

    require_authentication
    before_action :find_spotify, except: %i[index reviews decide]

    def index
      render json: Listening::SourceStatus.for(Current.user)
    end

    def disconnect
      Spotify::Account.new.disconnect!(@source)
      render json: Listening::SourceStatus.for(Current.user)
    end

    def sync
      return render(json: { error: "ingestion_disabled" }, status: :conflict) unless ListeningStorage.enabled?("spotify")
      return render(json: { error: "not_connected" }, status: :conflict) unless @source.connected?
      return render(json: { error: "paused" }, status: :conflict) if @source.paused?

      last = @source.polls.where(trigger: "manual").maximum(:started_at)
      if last && last > SYNC_INTERVAL.ago
        return render json: { error: "too_soon", retryAfter: (last + SYNC_INTERVAL).iso8601 }, status: :too_many_requests
      end

      SpotifyPollSourceJob.perform_later(@source.id, trigger: "manual", force: true)
      render json: { queued: true }, status: :accepted
    end

    def pause
      @source.update!(paused_at: Time.current) unless @source.paused?
      render json: Listening::SourceStatus.for(Current.user)
    end

    def resume
      @source.update!(paused_at: nil, next_poll_at: nil)
      render json: Listening::SourceStatus.for(Current.user)
    end

    # Plays a provider reported that might be plays already stored (Listening::CrossSource).
    def reviews
      render json: { items: Listening::ReviewQueue.for(Current.user) }
    end

    def decide
      observation = Current.user.listening_observations.pending_review.find_by(id: params[:id])
      return render(json: { error: "not_found" }, status: :not_found) unless observation

      result = case params[:decision]
      when "link" then Listening::Review.link!(observation, params[:scrobble_id].to_i, by: Current.user)
      when "separate" then Listening::Review.separate!(observation, by: Current.user)
      end
      render json: { result: result, items: Listening::ReviewQueue.for(Current.user) }
    rescue Listening::Review::Invalid => e
      render json: { error: "invalid", message: e.message }, status: :unprocessable_entity
    rescue ListeningStorage::DisabledError
      render json: { error: "ingestion_disabled" }, status: :conflict
    end

    private

    def find_spotify
      @source = Current.user.listening_sources.spotify.where.not(state: "disconnected").order(:id).last
      render(json: { error: "not_connected" }, status: :not_found) unless @source
    end
  end
end
