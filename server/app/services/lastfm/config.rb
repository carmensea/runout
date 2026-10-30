module Lastfm
  # API credentials come from the environment, falling back to Rails credentials.
  # The shared secret never leaves the server.
  module Config
    module_function

    def api_key
      ENV["LASTFM_API_KEY"].presence || Rails.application.credentials.dig(:lastfm, :api_key)
    end

    def shared_secret
      ENV["LASTFM_SHARED_SECRET"].presence || Rails.application.credentials.dig(:lastfm, :shared_secret)
    end

    # API credentials and at least one allowed account (Lastfm::AccountPolicy).
    def configured?
      api_key.present? && shared_secret.present? && AccountPolicy.configured?
    end

    # `overrides` adjust one client (for example, the probe uses max_attempts: 1). The test suite
    # sets config.x.lastfm_client_options so retries don't sleep.
    def client(**overrides)
      raise Error::NotConfigured, "Set LASTFM_API_KEY, LASTFM_SHARED_SECRET and LASTFM_ALLOWED_USERNAME." unless configured?

      options = { pacer: pacer }.merge(Rails.configuration.x.lastfm_client_options || {}).merge(overrides)
      Client.new(api_key: api_key, shared_secret: shared_secret, **options)
    end

    # Global pacing shared by every process (Lastfm::RequestPacer).
    def pacer
      RequestPacer.new(interval: ENV.fetch("LASTFM_MIN_REQUEST_INTERVAL", RequestPacer::DEFAULT_INTERVAL).to_f)
    end
  end
end
