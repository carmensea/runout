module Spotify
  # The OAuth `state` (docs/spotify-plan.md §8): encrypted and signed, valid for 10 minutes, naming
  # the Runout user who started the connection and a one-time nonce. The callback runs on the
  # loopback IP Spotify requires, where the session cookie (set for the app's own host) isn't
  # sent, so the state carries the user. The nonce is also put in a cookie on the callback's host
  # just before leaving for Spotify; the callback requires both, so a state can't be completed
  # in another browser.
  module OAuthState
    TTL = 10.minutes
    PURPOSE = "spotify_oauth_state".freeze

    module_function

    def issue(user_id)
      nonce = SecureRandom.urlsafe_base64(32)
      [ encryptor.encrypt_and_sign({ "u" => user_id, "n" => nonce }, expires_in: TTL, purpose: PURPOSE), nonce ]
    end

    # { "u" => user_id, "n" => nonce }, or nil when invalid or expired.
    def read(state)
      data = encryptor.decrypt_and_verify(state.to_s, purpose: PURPOSE)
      data.is_a?(Hash) && data["u"].present? && data["n"].present? ? data : nil
    rescue ActiveSupport::MessageEncryptor::InvalidMessage, ActiveSupport::MessageVerifier::InvalidSignature
      nil
    end

    def encryptor
      key = Rails.application.key_generator.generate_key("runout spotify oauth state", ActiveSupport::MessageEncryptor.key_len)
      ActiveSupport::MessageEncryptor.new(key, cipher: "aes-256-gcm")
    end
  end
end
