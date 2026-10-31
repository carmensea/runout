# Metadata enrichment (docs/milestone-4-plan.md §5). Fetching needs METADATA_ENRICHMENT_ENABLED;
# status and recomputing don't.
namespace :enrich do
  desc "Queue identified artists for enrichment, most played first: LIMIT=100 (all when unset)"
  task plan: :environment do
    limit = ENV["LIMIT"].presence&.to_i
    total = Metadata::Planner.plan!(limit: limit)
    puts "Queued: #{total} artists in all#{" (the #{limit} most played requested)" if limit}."
  end

  desc "Enrich due targets now, in this process: LIMIT=100"
  task run: :environment do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    summary = Metadata::Enricher.new.run!(limit: ENV.fetch("LIMIT", "100").to_i)
    puts summary.to_h.map { |k, v| "#{k}=#{v}" }.join(" ") + format(" elapsed=%.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end

  desc "Queue played releases for artwork, most played first: LIMIT=50 (all when unset)"
  task plan_artwork: :environment do
    limit = ENV["LIMIT"].presence&.to_i
    puts "Queued: #{Metadata::Artwork.plan!(limit: limit)} releases in all#{" (the #{limit} most played requested)" if limit}."
  end

  desc "Fetch due artwork now, in this process: LIMIT=50"
  task run_artwork: :environment do
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    summary = Metadata::Artwork::Enricher.new.run!(limit: ENV.fetch("LIMIT", "50").to_i)
    puts summary.to_h.map { |k, v| "#{k}=#{v}" }.join(" ") + format(" elapsed=%.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
  end

  desc "Enrichment progress"
  task status: :environment do
    Metadata::Progress.report.each { |k, v| puts format("%-28s %s", k, v.inspect) }
  end
end

namespace :genres do
  desc "Rebuild every artist's genre classification (after taxonomy or override changes)"
  task recompute: :environment do
    puts "Classified #{Genres::Classifications.recompute!} artists."
  end
end

namespace :taxonomy do
  desc "Provider genre and tag names the taxonomy doesn't map, by the plays of the artists carrying them"
  task unmapped: :environment do
    plays = Metadata::Planner.played_artists.to_h
    mapped = TagGenreMapping.distinct.pluck(:tag).to_set
    rows = MetadataTag.where(entity_kind: "artist").pluck(:provider_id, :kind, :name)
                      .reject { |_, _, name| mapped.include?(TagGenreMapping.normalize(name)) }
                      .group_by { |_, kind, name| [ kind, TagGenreMapping.normalize(name) ] }
                      .map { |(kind, name), list| [ kind, name, list.size, list.sum { |id, _, _| plays[id].to_i } ] }
                      .sort_by { |_, _, _, n| -n }
    puts format("%-6s %-40s %8s %10s", "kind", "name", "artists", "plays")
    rows.first(ENV.fetch("LIMIT", "50").to_i).each { |kind, name, artists, n| puts format("%-6s %-40s %8d %10d", kind, name, artists, n) }
  end
end
