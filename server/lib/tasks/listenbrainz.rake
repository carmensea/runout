namespace :listenbrainz do
  desc "Run a ListenBrainz account's history backfill to completion, now, in this process (SOURCE=<listening_sources.id>, PAGES=<per run>; needs LISTENBRAINZ_INGESTION_ENABLED)"
  task backfill: :environment do
    source = ListeningSource.where(provider: "listenbrainz").find(ENV.fetch("SOURCE"))
    backfill = Listenbrainz::Backfill.new
    loop do
      result = backfill.run!(source, pages: Integer(ENV.fetch("PAGES", Listenbrainz::Backfill::PAGES_PER_RUN)), trigger: "task")
      source.reload
      puts "#{result.status}: #{source.backfill_fetched}/#{source.backfill_total || '?'} read, back to #{source.backfill_before&.utc&.iso8601 || '-'}, #{result.poll&.recorded.to_json}"
      break unless result.status == :partial
    end
  end
end
