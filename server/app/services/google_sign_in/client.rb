require "net/http"
require "jwt"

module GoogleSignIn
  # The two calls of the OpenID Connect code flow: exchange the callback's code for an ID token
  # (server to server, with the client secret), then verify that token. Verification is the `jwt`
  # library's: signature against Google's published keys, issuer, audience and expiry; the nonce
  # ties the token to the browser that started the flow. Nothing here is logged: codes, tokens and
  # the secret never reach the logs or the browser.
  class Client
    class Error < StandardError; end
    # Google refused the code, or could not be reached.
    class ExchangeFailed < Error; end
    # The ID token did not verify: wrong signature, issuer, audience, nonce, or expired.
    class InvalidToken < Error; end

    Verified = Data.define(:sub, :email)

    JWKS_TTL = 1.hour

    # Who signed in, verified. Raises ExchangeFailed or InvalidToken.
    def identity_for(code:, nonce:)
      verify(exchange(code), nonce: nonce)
    end

    def exchange(code)
      response = Net::HTTP.post_form(URI(Config::TOKEN_URL), code: code, client_id: Config.client_id, client_secret: Config.client_secret,
                                                             redirect_uri: Config.redirect_uri, grant_type: "authorization_code")
      raise ExchangeFailed, "token endpoint answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)["id_token"].presence or raise ExchangeFailed, "no id_token in the answer"
    rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise ExchangeFailed, e.class.name
    end

    def verify(id_token, nonce:)
      payload, = JWT.decode(id_token, nil, true, algorithms: [ "RS256" ], jwks: method(:jwks),
                            iss: Config::ISSUERS, verify_iss: true, aud: Config.client_id, verify_aud: true,
                            verify_expiration: true, verify_iat: true, required_claims: %w[sub exp iss aud])
      raise InvalidToken, "nonce mismatch" unless nonce.present? && ActiveSupport::SecurityUtils.secure_compare(payload["nonce"].to_s, nonce)
      raise InvalidToken, "no subject" if payload["sub"].blank?

      # The address is shown to its owner in Settings and never used to find or match an account.
      Verified.new(sub: payload["sub"].to_s, email: (payload["email"].to_s.presence if payload["email_verified"] == true))
    rescue JWT::DecodeError => e
      raise InvalidToken, e.class.name
    end

    private

    # Google's signing keys, cached; fetched again when a token names a key we do not have yet.
    def jwks(options = {})
      Rails.cache.delete(cache_key) if options[:kid_not_found]
      Rails.cache.fetch(cache_key, expires_in: JWKS_TTL) do
        response = Net::HTTP.get_response(URI(Config::JWKS_URL))
        raise ExchangeFailed, "keys endpoint answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      end
    rescue JSON::ParserError, SocketError, SystemCallError, Timeout::Error, OpenSSL::SSL::SSLError => e
      raise ExchangeFailed, e.class.name
    end

    def cache_key = "google_sign_in/jwks"
  end
end
