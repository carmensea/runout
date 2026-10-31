Rails.application.routes.draw do
  # Health check for Render.
  get "up" => "rails/health#show", as: :rails_health_check

  scope :api, module: :api, defaults: { format: :json } do
    get "auth/lastfm", to: "lastfm_auth#start", as: :lastfm_sign_in
    get "auth/lastfm/callback", to: "lastfm_auth#callback", as: :lastfm_callback
    get "auth/spotify", to: "spotify_auth#start", as: :spotify_connect
    get "auth/spotify/begin", to: "spotify_auth#begin_flow", as: :spotify_begin
    get "auth/spotify/callback", to: "spotify_auth#callback", as: :spotify_callback
    get "listening-sources", to: "listening_sources#index", as: :listening_sources
    post "listening-sources/spotify/disconnect", to: "listening_sources#disconnect", as: :spotify_disconnect
    resource :session, only: :destroy
    resource :account, only: :destroy
    resource :connection, only: :show
    resource :import, only: %i[show create] do
      post :pause
      post :resume
      post :cancel
      post "periods/:id/retry", action: :retry_period, as: :retry_period
    end
    resource :sync, only: :show do
      post :refresh
      post :pause
      post :resume
    end
    resources :reviews, only: :index
    post "reviews/:kind/:id/:decision", to: "reviews#decide", as: :review_decision,
                                        constraints: { kind: /removal|reappeared|dispute/, id: /\d+/ }
    resource :overview, only: :show
    resource :search, only: :show
    resource :calendar, only: :show
    resources :plays, only: :index
    resource :on_this_day, only: :show, path: "on-this-day"
    get "genres/:slug", to: "genres#show", as: :genre, constraints: { slug: /[a-z0-9-]+/ }
  end
end
