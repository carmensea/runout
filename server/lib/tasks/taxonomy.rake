namespace :taxonomy do
  desc "Apply server/db/seeds/taxonomy.yml (the owner's manual rows are kept)"
  task seed: :environment do
    Genres::Seed.new.apply!
    puts "Taxonomy: #{Genre.broad.count} broad genres, #{Genre.where(level: 'sub').count} subgenres, " \
         "#{TagGenreMapping.count} mappings (#{TagGenreMapping.where(origin: 'manual').count} manual)."
  end
end
