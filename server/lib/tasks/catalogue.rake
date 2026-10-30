namespace :catalogue do
  desc "Match name variants to canonical artists, albums and tracks (offline; refuses while history storage is off)"
  task match: :environment do
    count = Catalogue::Matcher.new.match_pending!
    open_reviews = CatalogueReview.open.group(:level, :kind).count
    puts "Matched #{count} name variants. Open reviews: #{open_reviews.empty? ? 'none' : open_reviews.map { |(l, k), n| "#{l} #{k}: #{n}" }.join(', ')}"
  end
end
