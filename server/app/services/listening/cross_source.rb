module Listening
  # Is a new provider's play one already stored from another provider? (docs/spotify-plan.md §5;
  # docs/long-term-architecture.md §6; docs/listenbrainz-spotify-feasibility.md §4.3). Read-only:
  # it decides, Listening::Recorder writes.
  #
  # Two rules, in order.
  #
  # 1. The same external event. Runout's own Spotify observations and ListenBrainz's Spotify import
  #    both carry Spotify's `played_at` and track id. Same user, same `provider_track_id`, reported
  #    within a second of each other, from another provider: the same play, linked. Genuine repeats
  #    never share a timestamp.
  #
  # 2. The same play by start time. Each report and each stored play gives a span where its start
  #    must lie, from its timestamp and what that means (Listening::KINDS): a start stamp (Last.fm,
  #    scrobblers) is the start; an end-of-play stamp (Spotify) puts the start between a full
  #    `duration_ms` and the scrobble threshold (half the track, at most four minutes) before it. A
  #    play started later than that would have been too short to count; one started earlier is the
  #    previous play. So a track played twice in a row gives each report one candidate, not two. The
  #    usual window: the two spans meet, give or take SLACK for clock differences. Plays another
  #    observation from the same provider already attests are not candidates: each play is attested
  #    at most once per provider.
  #
  #    Real plays don't always fit that (docs/spotify-plan.md §12): Last.fm sometimes stamps a play
  #    with its end, not its start, and a skipped play's start can't be computed, because Spotify
  #    reports the track's length, not how much was heard. So a wider NEAR span is also searched,
  #    from the earliest start to the stamp itself. A play of the same track found only there is
  #    never linked and never ignored: it goes to a person. A timestamp whose meaning is unknown
  #    (`listenbrainz_listened_at`) never links by itself: a play of the same track nearby goes to a
  #    person too.
  #
  # Identity, per candidate:
  # - same: the same catalogue track, or the same artist and title once normalised (case, Unicode,
  #   spacing; CatalogName.normalize). The album is ignored: providers name editions differently.
  # - similar: the same normalised artist and the same title once a trailing " - ..." and bracketed
  #   parts are removed ("Song - 2011 Remaster", "Song (Live)"). Never merged automatically.
  #
  # Decision, in order:
  # - exactly one `same` candidate in the usual window: linked (a repeat's neighbours may sit in the
  #   near window; they belong to the neighbouring reports);
  # - more than one `same` there, or `similar` ones, or `same`/`similar` ones only in the near
  #   window: a person decides;
  # - otherwise a new play. Timestamps alone never link two plays.
  class CrossSource
    SLACK = 30.seconds
    THRESHOLD = 240 # seconds: a scrobble needs half the track or four minutes, whichever is less
    EXACT = 1.second # how far apart two providers' stamps of one Spotify play can be
    LONGEST_TRACK = 1.hour # bounds the candidate query; the precise spans are applied in Ruby
    START_KINDS = %w[lastfm_start listen_started_at].freeze
    END_KINDS = %w[spotify_played_at].freeze

    Decision = Data.define(:action, :scrobble_id, :evidence) # action: :create, :link, :review

    Candidate = Data.define(:scrobble_id, :source, :played_at, :artist_name, :track_name, :track_id, :timestamp_kind, :duration_ms) do
      def start_span = CrossSource.start_span(played_at, timestamp_kind, duration_ms)
      def near_span = start_span.begin..played_at
      def known? = CrossSource.known?(timestamp_kind)
    end

    # Where a play's start can lie, given its stamp and what the stamp means. A stored play without
    # an observation (Last.fm) is stamped with its start.
    def self.start_span(at, kind, duration_ms)
      duration = duration_ms.to_i / 1000.0
      if END_KINDS.include?(kind) then (at - duration)..(at - [ duration / 2, THRESHOLD ].min)
      elsif kind.nil? || START_KINDS.include?(kind) then at..at
      else (at - duration)..at # unknown meaning: either reading
      end
    end

    def self.known?(kind) = kind.nil? || START_KINDS.include?(kind) || END_KINDS.include?(kind)

    def initialize(user_id:, provider:)
      @user_id = user_id
      @provider = provider
    end

    # Where another provider's start of this play is expected.
    def window(event) = self.class.start_span(event.reported_at, event.timestamp_kind, event.duration_ms)

    # Where another provider's timestamp of this play can still be: never linked from here.
    def near_window(event) = window(event).begin..event.reported_at

    def decide(event, variant)
      exact = same_external_event(event)
      if exact.any?
        evidence = { rule: "same_external_event", provider_track_id: event.provider_track_id, candidates: exact }
        return Decision.new(action: :link, scrobble_id: exact.first[:scrobble_id], evidence: evidence.merge(reason: "same_external_event")) if exact.size == 1

        return Decision.new(action: :review, scrobble_id: nil, evidence: evidence.merge(reason: "several_same_external_events"))
      end

      usual = window(event)
      near = near_window(event)
      known = self.class.known?(event.timestamp_kind)
      track_root = root_track(variant.track_id)
      rated = candidates(near).filter_map do |c|
        next unless meet?(c.near_span, near)

        [ c, identity(c, variant, track_root), known && c.known? && meet?(c.start_span, usual) ? :usual : :near ]
      end
      pick = ->(rating, where) { rated.select { |_, r, w| r == rating && (where.nil? || w == where) }.map(&:first) }
      same = pick.(:same, :usual)
      evidence = { rule: "cross_source_v3", kind: event.timestamp_kind, window: [ usual.begin.iso8601(3), usual.end.iso8601(3) ],
                   near_window: [ near.begin.iso8601(3), near.end.iso8601(3) ],
                   candidates: rated.map { |c, rating, where| describe(c, rating, where, event) } }
      decision = lambda do |action, reason, id = nil|
        Decision.new(action: action, scrobble_id: id, evidence: evidence.merge(reason: reason))
      end

      if same.size == 1 then decision.(:link, "one_same_play", same.first.scrobble_id)
      elsif same.size > 1 then decision.(:review, "several_same_plays")
      elsif pick.(:similar, :usual).any? then decision.(:review, "similar_play")
      elsif !known && (pick.(:same, nil) + pick.(:similar, nil)).any? then decision.(:review, "unknown_timestamp_kind")
      elsif pick.(:same, :near).any? then decision.(:review, "same_track_unexpected_time")
      elsif pick.(:similar, :near).any? then decision.(:review, "similar_play_unexpected_time")
      else decision.(:create, rated.any? { |_, _, w| w == :usual } ? "different_plays" : "no_play_nearby")
      end
    end

    private

    # Two spans meet once one is widened by SLACK on both sides.
    def meet?(a, b) = a.begin <= b.end + SLACK && a.end >= b.begin - SLACK

    # Rule 1: another provider's observation of the same Spotify play, not yet attested by this one.
    def same_external_event(event)
      return [] if event.provider_track_id.blank?

      ListeningObservation.where(user_id: @user_id, provider_track_id: event.provider_track_id).where.not(provider: @provider)
                          .where(reported_at: (event.reported_at - EXACT)..(event.reported_at + EXACT))
                          .where(scrobble_id: Scrobble.present.where(user_id: @user_id))
                          .where("NOT EXISTS (SELECT 1 FROM listening_observations o WHERE o.scrobble_id = listening_observations.scrobble_id AND o.provider = ?)", @provider)
                          .order(:reported_at).pluck(:scrobble_id, :provider, :reported_at)
                          .map { |id, provider, at| { scrobble_id: id, source: provider, reported_at: at.utc.iso8601(3), identity: "same_external_event" } }
                          .uniq { |c| c[:scrobble_id] }
    end

    # Stored plays of other sources whose own stamp could belong to this report, with the stamp's
    # meaning and the track length from the observation that created them (none for Last.fm).
    def candidates(near)
      Scrobble.present.where(user_id: @user_id).where.not(source: @provider)
              .where(played_at: (near.begin - SLACK)..(near.end + SLACK + LONGEST_TRACK))
              .where("NOT EXISTS (SELECT 1 FROM listening_observations o WHERE o.scrobble_id = scrobbles.id AND o.provider = ?)", @provider)
              .joins(:name_variant)
              .joins("LEFT JOIN listening_observations created ON created.scrobble_id = scrobbles.id AND created.link_state = 'created'")
              .order(:played_at, :seq)
              .pluck("scrobbles.id", "scrobbles.source", "scrobbles.played_at", "name_variants.artist_name", "name_variants.track_name",
                     "name_variants.track_id", "created.timestamp_kind", "created.duration_ms")
              .map { |row| Candidate.new(*row) }
    end

    def identity(candidate, variant, track_root)
      return :same if track_root && root_track(candidate.track_id) == track_root
      return :none unless CatalogName.normalize(candidate.artist_name) == CatalogName.normalize(variant.artist_name)
      return :same if CatalogName.normalize(candidate.track_name) == CatalogName.normalize(variant.track_name)

      core(candidate.track_name) == core(variant.track_name) ? :similar : :none
    end

    def core(title)
      CatalogName.normalize(title.to_s.sub(/\s+-\s+.*\z/, "").gsub(/\s*[(\[][^)\]]*[)\]]/, ""))
    end

    def root_track(id)
      return nil unless id

      (@roots ||= {})[id] ||= Track.find_by(id: id)&.resolved&.id
    end

    def describe(candidate, rating, where, event)
      { scrobble_id: candidate.scrobble_id, source: candidate.source, played_at: candidate.played_at.utc.iso8601,
        kind: candidate.timestamp_kind, seconds_before_report: (event.reported_at - candidate.played_at).round(1),
        identity: rating.to_s, window: where.to_s }
    end
  end
end
