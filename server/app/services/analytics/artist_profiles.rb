module Analytics
  # What is known about the artists behind a set of plays, by the Overview's artist keys ("a<id>" for
  # a catalogue artist at the end of its merge chain, "n<hash>" for a name-only one): its genre
  # classification and its listed type and gender, with why either may be missing
  # (docs/milestone-4-plan.md §4, §6). Missing is a category of its own, never dropped:
  #
  # - not_identified: no MusicBrainz ID (name-only), so nothing can be looked up;
  # - not_looked_up: identified, but enrichment hasn't fetched it yet;
  # - no_genres: looked up, and the provider lists no genres the taxonomy maps;
  # - classified.
  module ArtistProfiles
    Profile = Data.define(:status, :genres, :kind)

    UNCLASSIFIED = Genres::Classifier::Result.new(broad: { "unclassified" => 1.0 }, sub: { "unclassified" => 1.0 }, present: Set.new, signals_used: [])

    # Listed type and gender, as categories (src/data/types.ts ArtistKindKey). Never inferred: a group
    # is a group whoever is in it, and a person without a listed gender stays unlisted.
    def self.kind_of(artist_type, gender)
      case artist_type
      when "Person"
        { "Female" => "female", "Male" => "male", "Non-binary" => "nonbinary", "Other" => "other_gender" }.fetch(gender, "person_unlisted")
      when "Group" then "group"
      when "Orchestra", "Choir" then "orchestra_choir"
      when nil then "type_unlisted"
      else "other_type"
      end
    end

    module_function

    # `genres: false` skips the classifications, for callers that only need the kinds.
    def for_keys(keys, genres: true)
      ids = keys.filter_map { |k| k[1..].to_i if k.start_with?("a") }
      mbids = Artist.where(id: ids).where.not(mbid: nil).pluck(:id, :mbid).to_h
      found = MetadataArtist.where(provider: Metadata::Enrichment::PROVIDER, provider_id: mbids.values).pluck(:provider_id, :artist_type, :gender)
                            .to_h { |id, type, gender| [ id, [ type, gender ] ] }
      overrides = MetadataOverride.where(entity_kind: "artist", provider_id: mbids.values, field: %w[artist_type gender])
                                  .pluck(:provider_id, :field, :value).group_by(&:first)
      classes = genres ? GenreClassification.where(level: "artist", provider_id: mbids.values).index_by(&:provider_id) : {}

      keys.to_h do |key|
        mbid = key.start_with?("a") ? mbids[key[1..].to_i] : nil
        c = mbid && classes[mbid]
        status = if mbid.nil? then :not_identified
        elsif !found.key?(mbid) && c.nil? then :not_looked_up
        elsif c.nil? || c.unclassified then :no_genres
        else :classified
        end
        genres = status == :classified ? Genres::Classifier::Result.new(broad: c.broad, sub: c.sub, present: c.present.to_set, signals_used: c.signals_used) : UNCLASSIFIED
        kind = if mbid.nil? then "not_identified"
        elsif !found.key?(mbid) then "not_looked_up"
        else
                 type, gender = found[mbid]
                 Array(overrides[mbid]).each { |_, field, value| field == "artist_type" ? type = value : gender = value }
                 kind_of(type, gender)
        end
        [ key, Profile.new(status: status, genres: genres, kind: kind) ]
      end
    end
  end
end
