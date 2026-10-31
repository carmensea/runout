namespace :catalogue do
  desc "Match name variants to canonical artists, albums and tracks (offline; refuses while history storage is off)"
  task match: :environment do
    count = Catalogue::Matcher.new.match_pending!
    open_reviews = CatalogueReview.open.group(:level, :kind).count
    puts "Matched #{count} name variants. Open reviews: #{open_reviews.empty? ? 'none' : open_reviews.map { |(l, k), n| "#{l} #{k}: #{n}" }.join(', ')}"
  end

  desc "Artist names without an ID that would join the one identified artist with that name (read-only; APPLY=1 to apply)"
  task infer_artists: :environment do
    inference = Catalogue::ArtistInference.new
    candidates = inference.candidates
    eligible, excluded = candidates.partition(&:eligible?)
    puts "Name-only artists sharing a name with an identified one: #{candidates.size}"
    puts "Would join their identified artist: #{eligible.size} (#{eligible.sum { |c| c.variant_ids.size }} name variants, " \
         "#{eligible.sum(&:plays)} plays; #{eligible.sum { |c| c.albums.size }} name-only albums and #{eligible.sum { |c| c.tracks.size }} " \
         "tracks join same-titled ones)"
    puts "Excluded: #{excluded.size}"
    excluded.group_by(&:excluded).each do |reason, list|
      puts "  #{reason}: #{list.size} (#{list.sum(&:plays)} plays)"
      list.sort_by { |c| -c.plays }.first(10).each { |c| puts format("    %-40s %6d plays", c.from.name, c.plays) }
    end
    next puts "Dry run: nothing changed. Run with APPLY=1 to apply." unless ENV["APPLY"] == "1"

    applied = inference.apply!(candidates)
    puts "Applied #{applied.size} inferences."
  end

  desc "Undo one artist inference: ID=<catalogue_inferences id>"
  task revert_inference: :environment do
    inference = CatalogueInference.applied.find(ENV.fetch("ID"))
    Catalogue::ArtistInference.new.revert!(inference)
    puts "Reverted inference #{inference.id} (#{inference.normalized_name})."
  end
end
