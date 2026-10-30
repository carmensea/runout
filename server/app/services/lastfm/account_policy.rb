module Lastfm
  # Which Last.fm accounts may sign in to this Runout deployment.
  #
  # Last.fm exposes no stable account ID (user.getInfo returns none, in JSON or XML), and
  # usernames can change. So for now a deployment is locked to explicitly configured accounts:
  #
  # - Single-account mode (one configured username, the private deployment): once the account is
  #   linked, no other Last.fm username can create a second Runout user. A renamed account must be
  #   relinked explicitly by the operator (bin/rails lastfm:relink); nothing is merged or guessed.
  # - Multi-account mode (several configured usernames) exists so the schema and code stay ready for
  #   more users; each configured username maps to its own Runout user.
  module AccountPolicy
    module_function

    # Normalised usernames allowed to sign in. Last.fm usernames are case-insensitive.
    def allowed_usernames
      Array(Rails.configuration.x.lastfm_allowed_usernames).map { |name| normalize(name) }.reject(&:empty?).uniq
    end

    def configured?
      allowed_usernames.any?
    end

    def single_account?
      allowed_usernames.size == 1
    end

    def allowed?(username)
      allowed_usernames.include?(normalize(username))
    end

    def normalize(username)
      username.to_s.strip.downcase
    end
  end
end
