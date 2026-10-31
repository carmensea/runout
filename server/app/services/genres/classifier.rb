module Genres
  # One item's genres (an artist now; a release group or recording later): docs/backend-plan.md §6
  # and docs/milestone-4-plan.md §3. Pure arithmetic over provider signals; no database, no network.
  #
  # 1. Each signal (a provider genre or tag with its votes) is weighted against the item's strongest,
  #    which counts 100. Signals below `min_tag_weight` are dropped.
  # 2. A signal's weight is shared out over the genres its name maps to (TagGenreMapping weights).
  #    A subgenre's score also counts for its broad genre.
  # 3. If the broad scores add up to at least `min_mapped_weight`, the broad shares are the scores
  #    over their total: they add up to exactly 1. Otherwise the item is Unclassified (share 1).
  # 4. Within each broad genre, the share is split over its subgenres by their scores. Weight given to
  #    the broad genre itself (a "rock" tag, or `also` in the seed) goes to "Other <genre>", so the
  #    subgenre shares add up to their broad genre's share.
  #
  # Unmapped names count for nothing, and nothing is guessed: an item without enough mapped weight is
  # Unclassified, never assigned a nearest genre.
  class Classifier
    UNCLASSIFIED = "unclassified".freeze

    Signal = Data.define(:name, :votes)

    # `broad`: { broad slug => share }, or { "unclassified" => 1.0 }. `sub`: { sub slug or
    # "other:<broad slug>" => share }. `present`: every genre slug with any mapped weight, for reach.
    Result = Data.define(:broad, :sub, :present, :signals_used) do
      def unclassified? = broad.key?(UNCLASSIFIED)
    end

    # `mappings`: { normalised name => [[genre slug, weight], ...] }; `genres`: { slug => [level, parent slug] }.
    def initialize(mappings:, genres:, settings: TaxonomySetting::DEFAULTS)
      @mappings = mappings
      @genres = genres
      @min_tag_weight = settings.fetch("min_tag_weight").to_f
      @min_mapped_weight = settings.fetch("min_mapped_weight").to_f
    end

    # From the taxonomy as stored.
    def self.from_database
      genres = Genre.includes(:parent).to_h { |g| [ g.slug, [ g.level, g.parent&.slug ] ] }
      ids = Genre.pluck(:id, :slug).to_h
      mappings = TagGenreMapping.pluck(:tag, :genre_id, :weight).group_by(&:first)
                                .transform_values { |list| list.map { |_, id, w| [ ids.fetch(id), w.to_f ] } }
      new(mappings: mappings, genres: genres, settings: TaxonomySetting.values)
    end

    def call(signals)
      signals = signals.map { |s| s.is_a?(Signal) ? s : Signal.new(**s) }.select { |s| s.votes.to_f.positive? }
      strongest = signals.map { |s| s.votes.to_f }.max
      return unclassified([]) unless strongest

      broad = Hash.new(0.0)
      sub = Hash.new(0.0)
      used = []
      signals.each do |s|
        weight = s.votes.to_f * 100 / strongest
        next if weight < @min_tag_weight

        targets = @mappings[TagGenreMapping.normalize(s.name)]
        next unless targets

        used << s.name
        targets.each do |slug, share|
          level, parent = @genres.fetch(slug)
          score = weight * share
          if level == "sub"
            sub[slug] += score
            broad[parent] += score
          else
            broad[slug] += score
          end
        end
      end

      total = broad.values.sum
      return unclassified(used) if total < @min_mapped_weight

      broad_shares = broad.transform_values { |score| score / total }
      sub_shares = {}
      broad.each do |slug, score|
        subs = sub.select { |s, _| @genres.fetch(s)[1] == slug }
        subs.each { |s, sub_score| sub_shares[s] = broad_shares[slug] * sub_score / score }
        rest = score - subs.values.sum
        sub_shares["other:#{slug}"] = broad_shares[slug] * rest / score if rest > score * 1e-9
      end
      Result.new(broad: broad_shares, sub: sub_shares, present: (broad.keys + sub.keys).to_set, signals_used: used)
    end

    private

    def unclassified(used)
      Result.new(broad: { UNCLASSIFIED => 1.0 }, sub: { UNCLASSIFIED => 1.0 }, present: Set.new, signals_used: used)
    end
  end
end
