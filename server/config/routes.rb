Rails.application.routes.draw do
  # Health check for Render.
  get "up" => "rails/health#show", as: :rails_health_check

  scope :api, module: :api, defaults: { format: :json } do
    get "auth/lastfm", to: "lastfm_auth#start", as: :lastfm_sign_in
    get "auth/lastfm/callback", to: "lastfm_auth#callback", as: :lastfm_callback
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
    get "overview", to: "unavailable#show"
    get "search", to: "unavailable#show"
  end
end
