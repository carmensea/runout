require "yaml"

module Genres
  # Applies server/db/seeds/taxonomy.yml (docs/milestone-4-plan.md §3), idempotently: genres by slug,
  # mappings by tag and genre, settings by key. The owner's rows (origin `manual`) are never changed;
  # seed mappings no longer in the file are removed. Reference data only.
  class Seed
    PATH = Rails.root.join("db/seeds/taxonomy.yml")

    class Invalid < StandardError; end

    def initialize(path = PATH)
      @data = YAML.safe_load_file(path, symbolize_names: true)
    end

    # The mappings the file describes: [[tag, genre slug, weight]].
    def mappings
      broad = @data.fetch(:broad).flat_map { |g| Array(g[:tags]).map { |t| [ TagGenreMapping.normalize(t), g[:slug].to_s, 1.0 ] } }
      sub = @data.fetch(:subgenres).flat_map do |g|
        also = (g[:also] || {}).transform_keys(&:to_s)
        own = 1.0 - also.values.sum
        Array(g[:tags]).flat_map do |t|
          tag = TagGenreMapping.normalize(t)
          [ [ tag, g[:slug].to_s, own ], *also.map { |slug, w| [ tag, slug, w.to_f ] } ]
        end
      end
      broad + sub
    end

    def validate!
      slugs = (@data[:broad] + @data[:subgenres]).map { |g| g[:slug].to_s }
      raise Invalid, "duplicate slugs: #{slugs.tally.select { |_, n| n > 1 }.keys}" if slugs.uniq.size != slugs.size

      broad = @data[:broad].map { |g| g[:slug].to_s }
      @data[:subgenres].each do |g|
        raise Invalid, "#{g[:slug]}: unknown parent #{g[:parent]}" unless broad.include?(g[:parent].to_s)

        also = (g[:also] || {}).transform_keys(&:to_s)
        raise Invalid, "#{g[:slug]}: `also` names a genre that isn't broad" unless (also.keys - broad).empty?
        raise Invalid, "#{g[:slug]}: `also` gives away all of the weight" unless also.values.sum < 1
      end
      tags = mappings.map(&:first).uniq { |t| t }
      owners = mappings.group_by(&:first).transform_values { |list| list.map { |_, slug, _| slug } }
      repeated = owners.select { |_, slugs| slugs.size != slugs.uniq.size }.keys
      raise Invalid, "a tag maps twice to one genre: #{repeated}" if repeated.any?

      listed = (@data[:broad].flat_map { |g| Array(g[:tags]) } + @data[:subgenres].flat_map { |g| Array(g[:tags]) }).map { |t| TagGenreMapping.normalize(t) }
      twice = listed.tally.select { |_, n| n > 1 }.keys
      raise Invalid, "tags listed under more than one genre: #{twice}" if twice.any?

      tags
    end

    def apply!
      validate!
      Genre.transaction do
        position = 0
        @data[:broad].each { |g| upsert_genre(g, level: "broad", parent: nil, position: position += 1) }
        broad = Genre.broad.index_by(&:slug)
        @data[:subgenres].each { |g| upsert_genre(g, level: "sub", parent: broad.fetch(g[:parent].to_s), position: position += 1) }

        genres = Genre.all.index_by(&:slug)
        wanted = mappings.to_h { |tag, slug, weight| [ [ tag, genres.fetch(slug).id ], weight ] }
        manual = TagGenreMapping.where(origin: "manual").pluck(:tag, :genre_id).to_set
        TagGenreMapping.where(origin: "seed").find_each do |m|
          m.destroy! unless wanted.key?([ m.tag, m.genre_id ])
        end
        wanted.each do |(tag, genre_id), weight|
          next if manual.include?([ tag, genre_id ])

          m = TagGenreMapping.find_or_initialize_by(tag: tag, genre_id: genre_id)
          m.update!(weight: weight.round(3), origin: "seed") if m.new_record? || m.origin == "seed"
        end

        @data.fetch(:settings, {}).each do |key, value|
          s = TaxonomySetting.find_or_initialize_by(key: key.to_s)
          s.update!(value: value, origin: "seed") if s.new_record? || s.origin == "seed"
        end
      end
    end

    private

    def upsert_genre(g, level:, parent:, position:)
      genre = Genre.find_or_initialize_by(slug: g[:slug].to_s)
      return if genre.persisted? && genre.origin == "manual"

      genre.update!(name: g[:name], level: level, parent: parent, position: position, origin: "seed")
    end
  end
end
