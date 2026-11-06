module Api
  # Listening sources in Settings (docs/spotify-plan.md §7, §10). Never returns credentials.
  class ListeningSourcesController < ApplicationController
    # "Sync now" at most this often; the recurring tick runs anyway.
    SYNC_INTERVAL = 1.minute

    require_authentication
    before_action :find_spotify, except: %i[index reviews decide connect_listenbrainz disconnect_listenbrainz backfill_listenbrainz]
    # Token attempts are bounded: a token is a secret somebody could guess at.
    rate_limit to: 10, within: 1.minute, only: :connect_listenbrainz, with: -> { render json: { error: "rate_limited" }, status: :too_many_requests }

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

    # POST /api/listening-sources/listenbrainz { token }: verifies the token once with ListenBrainz,
    # binds the username to this account, and forgets the token (Listenbrainz::Account).
    def connect_listenbrainz
      return render(json: { error: "ingestion_disabled" }, status: :conflict) unless ListeningStorage.enabled?("listenbrainz")
      return render(json: { error: "invalid_token" }, status: :unprocessable_content) if params[:token].to_s.strip.empty?

      Listenbrainz::Account.new.connect!(user: Current.user, token: params[:token])
      render json: Listening::SourceStatus.for(Current.user)
    rescue Listenbrainz::Account::InvalidToken then render json: { error: "invalid_token" }, status: :unprocessable_content
    rescue Listenbrainz::Account::AccountTaken then render json: { error: "account_taken" }, status: :conflict
    rescue Listenbrainz::Error::RateLimited => e then render json: { error: "rate_limited", retryAfter: (Time.current + e.retry_after).iso8601 }, status: :too_many_requests
    rescue Listenbrainz::Error => e
      Rails.logger.warn("ListenBrainz connection failed: #{e.class.name} #{e.message}")
      render json: { error: "unavailable" }, status: :service_unavailable
    end

    def disconnect_listenbrainz
      source = Current.user.listening_sources.where(provider: "listenbrainz").where.not(state: "disconnected").order(:id).last
      return render(json: { error: "not_connected" }, status: :not_found) unless source

      Listenbrainz::Account.new.disconnect!(source)
      render json: Listening::SourceStatus.for(Current.user)
    end

    # POST /api/listening-sources/listenbrainz/backfill: reads ListenBrainz now, then starts or
    # continues the full-history import (Listenbrainz::Backfill); the tick carries on from there.
    def backfill_listenbrainz
      return render(json: { error: "ingestion_disabled" }, status: :conflict) unless ListeningStorage.enabled?("listenbrainz")

      source = Current.user.listening_sources.where(provider: "listenbrainz", state: "connected").order(:id).last
      return render(json: { error: "not_connected" }, status: :conflict) unless source

      last = source.polls.where(trigger: "manual").maximum(:started_at)
      if last && last > SYNC_INTERVAL.ago
        return render json: { error: "too_soon", retryAfter: (last + SYNC_INTERVAL).iso8601 }, status: :too_many_requests
      end

      ListenbrainzPollSourceJob.perform_later(source.id, trigger: "manual", force: true)
      ListenbrainzBackfillJob.set(wait: 1.minute).perform_later(source.id)
      render json: { queued: true }, status: :accepted
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
