module Listening
  # A person's decision on an observation Listening::CrossSource couldn't decide (docs/spotify-plan.md
  # §5): it is the same play as one of the candidates, or a separate play. Audited in
  # review_decisions; nothing is decided automatically.
  module Review
    class Invalid < StandardError; end

    module_function

    def link!(observation, scrobble_id, by:)
      decide(observation, by) do |o|
        ids = Array(o.match_evidence["candidates"]).map { |c| c["scrobble_id"] }
        raise Invalid, "not one of the candidates" unless ids.include?(scrobble_id)

        scrobble = Scrobble.present.find_by(id: scrobble_id, user_id: o.user_id) or raise Invalid, "that play is gone"
        raise Invalid, "already attested by another #{o.provider} report" if ListeningObservation.exists?(scrobble_id: scrobble.id, provider: o.provider)

        o.update!(scrobble: scrobble, link_state: "linked", linked_by: "person")
        :linked
      end
    end

    def separate!(observation, by:)
      decide(observation, by) do |o|
        played_at = Time.at(o.reported_at.to_i).utc
        taken = Scrobble.where(user_id: o.user_id, played_at: played_at).maximum(:seq)
        scrobble = Scrobble.create!(user_id: o.user_id, played_at: played_at, seq: taken ? taken + 1 : 0, name_variant_id: o.name_variant_id,
                                    source: o.provider)
        o.update!(scrobble: scrobble, link_state: "created", linked_by: "person")
        :kept_separate
      end
    end

    def decide(observation, by)
      ListeningStorage.writing_for(observation.provider) do
        ApplicationRecord.transaction do
          ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", format(Recorder::LOCK, observation.user_id) ]))
          o = ListeningObservation.lock.find(observation.id)
          raise Invalid, "already decided" unless o.link_state == "pending_review"

          action = yield(o)
          ReviewDecision.record!(o, action, source: "person", by: by, scrobble_id: o.scrobble_id)
          action
        end
      end
    end
  end
end
