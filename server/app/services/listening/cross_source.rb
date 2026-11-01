module Listening
  # Is a new provider's play one already stored from another provider? (docs/spotify-plan.md §5;
  # docs/long-term-architecture.md §6). Read-only: it decides, Listening::Recorder writes.
  #
  # Candidates are the user's present plays from other sources whose start time can belong to this
  # report. For an end-of-play timestamp (Spotify's `played_at`), a play that another provider
  # counted started between a full `duration_ms` and the scrobble threshold (half the track, at most
  # four minutes) before it, give or take SLACK for clock differences. A play started later than
  # that would have been too short to count; one started earlier is the previous play. So a track
  # played twice in a row gives each report one candidate, not two. Plays another observation from
  # the same provider already attests are not candidates either: each play is attested at most
  # once per provider.
  #
  # Real plays don't always fit that (docs/spotify-plan.md §12): Last.fm sometimes stamps a play
  # with its end, not its start, and a skipped play's start can't be computed, because Spotify
  # reports the track's length, not how much was heard. So a wider NEAR window is also searched,
  # from a full `duration_ms` before the report to SLACK after it. A play of the same track found
  # only there is never linked and never ignored: it goes to a person.
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

    Decision = Data.define(:action, :scrobble_id, :evidence) # action: :create, :link, :review

    Candidate = Data.define(:scrobble_id, :source, :played_at, :artist_name, :track_name, :track_id)

    def initialize(user_id:, provider:)
      @user_id = user_id
      @provider = provider
    end

    # Where another provider's start of this play is expected.
    def window(event)
      duration = event.duration_ms.to_i / 1000.0
      case event.timestamp_kind
      when "spotify_played_at"
        (event.reported_at - duration - SLACK)..(event.reported_at - [ duration / 2, THRESHOLD ].min + SLACK)
      else
        raise ArgumentError, "no candidate window for #{event.timestamp_kind}"
      end
    end

    # Where another provider's timestamp of this play can still be: never linked from here.
    def near_window(event)
      (window(event).begin)..(event.reported_at + SLACK)
    end

    def decide(event, variant)
      usual = window(event)
      near = near_window(event)
      track_root = root_track(variant.track_id)
      rated = candidates(near).map { |c| [ c, identity(c, variant, track_root), usual.cover?(c.played_at) ? :usual : :near ] }
      pick = ->(rating, where) { rated.select { |_, r, w| r == rating && (where.nil? || w == where) }.map(&:first) }
      same = pick.(:same, :usual)
      evidence = { rule: "cross_source_v2", window: [ usual.begin.iso8601(3), usual.end.iso8601(3) ],
                   near_window: [ near.begin.iso8601(3), near.end.iso8601(3) ],
                   candidates: rated.map { |c, rating, where| describe(c, rating, where, event) } }
      decision = lambda do |action, reason, id = nil|
        Decision.new(action: action, scrobble_id: id, evidence: evidence.merge(reason: reason))
      end

      if same.size == 1 then decision.(:link, "one_same_play", same.first.scrobble_id)
      elsif same.size > 1 then decision.(:review, "several_same_plays")
      elsif pick.(:similar, :usual).any? then decision.(:review, "similar_play")
      elsif pick.(:same, :near).any? then decision.(:review, "same_track_unexpected_time")
      elsif pick.(:similar, :near).any? then decision.(:review, "similar_play_unexpected_time")
      else decision.(:create, rated.any? { |_, _, w| w == :usual } ? "different_plays" : "no_play_nearby")
      end
    end

    private

    def candidates(range)
      Scrobble.present.where(user_id: @user_id).where.not(source: @provider)
              .where(played_at: range)
              .where("NOT EXISTS (SELECT 1 FROM listening_observations o WHERE o.scrobble_id = scrobbles.id AND o.provider = ?)", @provider)
              .joins(:name_variant).order(:played_at, :seq)
              .pluck("scrobbles.id", "scrobbles.source", "scrobbles.played_at", "name_variants.artist_name", "name_variants.track_name",
                     "name_variants.track_id")
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
        seconds_before_report: (event.reported_at - candidate.played_at).round(1), identity: rating.to_s, window: where.to_s }
    end
  end
end
