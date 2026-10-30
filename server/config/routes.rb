Rails.application.routes.draw do
  # Health check for Render.
  get "up" => "rails/health#show", as: :rails_health_check

  scope :api, module: :api, defaults: { format: :json } do
    get "auth/lastfm", to: "lastfm_auth#start", as: :lastfm_sign_in
    get "auth/lastfm/callback", to: "lastfm_auth#callback", as: :lastfm_callback
    resource :session, only: :destroy
    resource :account, only: :destroy
    resource :connection, only: :show
    resource :sync, only: :show
  end
end
