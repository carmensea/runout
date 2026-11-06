Rails.application.routes.draw do
  # Health check for Railway.
  get "up" => "rails/health#show", as: :rails_health_check

  scope :api, module: :api, defaults: { format: :json } do
    get "auth/lastfm", to: "lastfm_auth#start", as: :lastfm_sign_in
    get "auth/lastfm/callback", to: "lastfm_auth#callback", as: :lastfm_callback
    get "auth/spotify", to: "spotify_auth#start", as: :spotify_connect
    get "auth/spotify/begin", to: "spotify_auth#begin_flow", as: :spotify_begin
    get "auth/spotify/callback", to: "spotify_auth#callback", as: :spotify_callback
    get "listening-sources", to: "listening_sources#index", as: :listening_sources
    post "listening-sources/spotify/disconnect", to: "listening_sources#disconnect", as: :spotify_disconnect
    post "listening-sources/spotify/sync", to: "listening_sources#sync", as: :spotify_sync
    post "listening-sources/spotify/pause", to: "listening_sources#pause", as: :spotify_pause
    post "listening-sources/spotify/resume", to: "listening_sources#resume", as: :spotify_resume
    post "listening-sources/listenbrainz", to: "listening_sources#connect_listenbrainz", as: :listenbrainz_connect
    post "listening-sources/listenbrainz/disconnect", to: "listening_sources#disconnect_listenbrainz", as: :listenbrainz_disconnect
    get "listening-sources/reviews", to: "listening_sources#reviews", as: :listening_reviews
    post "listening-sources/reviews/:id/:decision", to: "listening_sources#decide", as: :listening_review_decision,
                                                    constraints: { id: /\d+/, decision: /link|separate/ }
    resource :session, only: %i[show destroy]
    # Runout's own sign-in (docs/milestone-5-plan.md §2.3); 404 while RUNOUT_PASSKEYS_ENABLED is off.
    post "auth/passkey/options", to: "passkey_auth#options", as: :passkey_sign_in_options
    post "auth/passkey", to: "passkey_auth#create", as: :passkey_sign_in
    post "auth/recovery", to: "recovery_auth#create", as: :recovery_sign_in
    get "auth/link/:token", to: "sign_in_links#show", as: :sign_in_link
    get "passkeys", to: "passkeys#index", as: :passkeys
    post "passkeys/options", to: "passkeys#options", as: :passkey_options
    post "passkeys", to: "passkeys#create"
    delete "passkeys/:id", to: "passkeys#destroy", as: :passkey, constraints: { id: /\d+/ }
    post "recovery-codes", to: "recovery_codes#create", as: :recovery_codes
    resources :sessions, only: %i[index destroy], controller: "browser_sessions"
    resource :account, only: %i[update destroy]
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
    get "loved-tracks", to: "loved_tracks#index", as: :loved_tracks
  end

  # The React app's routes. Unknown API paths and missing asset files stay real 404s.
  root "frontend#show"
  get "*path", to: "frontend#show", format: false,
               constraints: ->(request) { !request.path.match?(%r{\A/(api|up)(/|\z)}) && File.extname(request.path).empty? }
end
