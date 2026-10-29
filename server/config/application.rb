require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Runout
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true

    # Session and sign-in state live in cookies; API-only apps omit this middleware by default.
    config.middleware.use ActionDispatch::Cookies

    # The browser-facing origin. The frontend and /api are served from it, so cookies stay
    # first-party and Last.fm redirects back here. In development this is the Vite server,
    # which proxies /api to Rails.
    config.x.app_origin = ENV.fetch("APP_ORIGIN", "http://localhost:5173")
    config.x.app_origins = [ config.x.app_origin ]

    # Scrobble timestamps are stored and compared in UTC; reporting timezones are applied in queries.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc
  end
end
