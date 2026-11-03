namespace :archive do
  desc "Read-only: write this database's Spotify record to FILE, for merging into another database"
  task export_spotify: :environment do
    path = ENV.fetch("FILE")
    source = ListeningSource.spotify.sole
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| Listening::ArchiveExport.new(source).write(file) }
    puts "Exported #{ListeningObservation.where(listening_source: source).count} observations to #{path}"
  end

  desc "Merge FILE into this database, a copy. Needs CONFIRM_DATABASE=<its name> and SPOTIFY_INGESTION_ENABLED=true for this command"
  task merge_spotify: :environment do
    report = Listening::ArchiveMerge.new(ENV.fetch("FILE")).run!(confirm_database: ENV["CONFIRM_DATABASE"])
    puts "Merged: #{report.tally.to_h}"
    puts "Held for a person's review: #{report.held_for_review}"
    puts "Decisions needing a person: #{report.conflicts.size}"
    report.conflicts.each { |line| puts "  #{line}" }
    puts "Catalogue and metadata decisions in the export, to review by hand: #{report.other_decisions.size}"
  end
end
