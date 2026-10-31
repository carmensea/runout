module Analytics
  # A period's artists by their listed type and gender (src/data/types.ts ArtistMetadata;
  # docs/milestone-4-plan.md §4): counted by artists and by plays. Only explicit provider values, or
  # the owner's corrections; unlisted, not yet looked up and not identified are categories of their
  # own and count in every total, so nothing missing disappears from a percentage.
  module ArtistKinds
    KINDS = %w[female male nonbinary other_gender person_unlisted group orchestra_choir other_type type_unlisted not_looked_up not_identified].freeze

    module_function

    # `plays`: { artist key => plays }.
    def call(plays)
      profiles = ArtistProfiles.for_keys(plays.keys, genres: false)
      by_artists = KINDS.index_with(0)
      by_scrobbles = KINDS.index_with(0)
      plays.each do |key, n|
        kind = profiles.fetch(key).kind
        by_artists[kind] += 1
        by_scrobbles[kind] += n
      end
      { byArtists: by_artists, byScrobbles: by_scrobbles, unmatchedArtists: by_artists["not_identified"],
        source: { provider: "MusicBrainz", license: "CC0", url: "https://musicbrainz.org" } }
    end
  end
end
