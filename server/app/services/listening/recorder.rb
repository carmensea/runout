module Listening
  # Stores provider reports of plays (docs/spotify-plan.md §3, §5). Each event in its own
  # transaction, under the user's history lock (the one Last.fm commits take), so two workers, or a
  # worker and a Last.fm commit, never interleave:
  #
  # - Already recorded (same source, same event ID): nothing new. `times_seen` and `last_seen_at`
  #   move on; anything reported differently is noted in `later_values`, never applied.
  # - Otherwise the exact strings become a name variant (no MusicBrainz IDs: the provider sends
  #   none), linked to the catalogue by the usual conservative rules (Catalogue::Matcher), and
  #   Listening::CrossSource decides: a new play (`created`, `source` = the provider, the next free
  #   slot in its second), a link to the matching play from another source (`linked`; that play is
  #   untouched), or a person's decision (`pending_review`, no play yet, not counted).
  #
  # The canonical time of a created play is the provider's timestamp truncated to the second; the
  # observation keeps it in full with its meaning.
  class Recorder
    Result = Data.define(:outcome, :observation) # outcome: :created, :linked, :pending_review, :seen, :changed

    LOCK = "history:%s".freeze

    def initialize(source, now: -> { Time.current })
      @source = source
      @now = now
    end

    # Events oldest first, so slots follow play order. Returns a tally of outcomes.
    def record_all!(events)
      events.sort_by(&:reported_at).map { |event| record!(event).outcome }.tally
    end

    def record!(event)
      raise ArgumentError, "event is for #{event.provider}, source is #{@source.provider}" unless event.provider == @source.provider

      ListeningStorage.writing_for(@source.provider) do
        ApplicationRecord.transaction do
          lock!
          existing = ListeningObservation.find_by(listening_source_id: @source.id, source_event_id: event.source_event_id)
          existing ? seen!(existing, event) : add!(event)
        end
      end
    end

    private

    def lock!
      ApplicationRecord.connection.execute(ApplicationRecord.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(hashtext(?))", format(LOCK, @source.user_id) ]))
    end

    def add!(event)
      variant = NameVariant.for!(artist_name: event.artist_name, track_name: event.track_name, album_name: event.album_name.to_s)
      Catalogue::Matcher.new.match!(variant)
      variant.reload
      decision = CrossSource.new(user_id: @source.user_id, provider: @source.provider).decide(event, variant)
      scrobble = case decision.action
      when :create then create_scrobble!(event, variant)
      when :link then decision.scrobble
      end
      state = { create: "created", link: "linked", review: "pending_review" }.fetch(decision.action)
      now = @now.call
      observation = ListeningObservation.create!(
        user_id: @source.user_id, listening_source: @source, provider: event.provider, source_event_id: event.source_event_id,
        reported_at: event.reported_at, reported_at_raw: event.reported_at_raw, timestamp_kind: event.timestamp_kind,
        duration_ms: event.duration_ms, name_variant: variant, provider_track_id: event.provider_track_id,
        provider_album_id: event.provider_album_id, provider_artist_ids: Array(event.provider_artist_ids), isrc: event.isrc,
        context: event.context, scrobble: scrobble, link_state: state, linked_by: state == "linked" ? "rule" : nil,
        match_evidence: decision.evidence, received_at: now, last_seen_at: now
      )
      Result.new(outcome: state.to_sym, observation: observation)
    end

    def create_scrobble!(event, variant)
      played_at = Time.at(event.reported_at.to_i).utc
      taken = Scrobble.where(user_id: @source.user_id, played_at: played_at).maximum(:seq)
      Scrobble.create!(user_id: @source.user_id, played_at: played_at, seq: taken ? taken + 1 : 0, name_variant: variant,
                       source: event.provider)
    end

    def seen!(observation, event)
      reported = { "provider_track_id" => event.provider_track_id, "provider_album_id" => event.provider_album_id,
                   "artist_name" => event.artist_name, "track_name" => event.track_name, "album_name" => event.album_name.to_s,
                   "duration_ms" => event.duration_ms, "isrc" => event.isrc }
      stored = { "provider_track_id" => observation.provider_track_id, "provider_album_id" => observation.provider_album_id,
                 "artist_name" => observation.name_variant.artist_name, "track_name" => observation.name_variant.track_name,
                 "album_name" => observation.name_variant.album_name, "duration_ms" => observation.duration_ms, "isrc" => observation.isrc }
      differs = reported.reject { |k, v| stored[k] == v }
      attributes = { times_seen: observation.times_seen + 1, last_seen_at: @now.call }
      attributes[:later_values] = differs if differs.any?
      observation.update!(attributes)
      Result.new(outcome: differs.any? ? :changed : :seen, observation: observation)
    end
  end
end
