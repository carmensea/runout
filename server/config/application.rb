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

    # The Last.fm account allowed to sign in (single-account private deployment). See
    # Lastfm::AccountPolicy; without it, sign-in is refused.
    config.x.lastfm_allowed_usernames = [ ENV["LASTFM_ALLOWED_USERNAME"] ].compact

    # Storing Last.fm listening history: off unless explicitly "true" or "1" (HistoryImport).
    config.x.history_import_enabled = ENV.fetch("LASTFM_HISTORY_STORAGE_ENABLED", "false")

    # Ongoing synchronisation (HistoryImport::Sync, docs/milestone-2-plan.md §5.2). The recurring
    # tick (config/recurring.yml) starts whichever kind is due; these say how often each is due.
    config.x.history_sync = {
      sync_every: ENV.fetch("SYNC_EVERY_MINUTES", 30).to_i.minutes,            # recent plays
      catch_up_every: ENV.fetch("SYNC_CATCH_UP_EVERY_HOURS", 24).to_i.hours,   # back-dated plays
      catch_up_span: ENV.fetch("SYNC_CATCH_UP_DAYS", 14).to_i.days,
      reconcile_every: ENV.fetch("SYNC_RECONCILE_EVERY_DAYS", 7).to_i.days,    # monthly count comparison
      lookback: ENV.fetch("SYNC_LOOKBACK_HOURS", 24).to_i.hours,               # rechecked by every sync
      settle: ENV.fetch("SYNC_SETTLE_MINUTES", 15).to_i.minutes,               # not fetched yet: still arriving
      rearm_after: ENV.fetch("SYNC_REARM_AFTER_HOURS", 24).to_i.hours,         # a period that gave up is tried again
      fresh_within: ENV.fetch("SYNC_FRESH_DAYS", 30).to_i.days                 # a verified month counts as current
    }

    # Scrobble timestamps are stored and compared in UTC; reporting timezones are applied in queries.
    config.time_zone = "UTC"
    config.active_record.default_timezone = :utc
  end
end
