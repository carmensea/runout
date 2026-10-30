# Ongoing synchronisation (HistoryImport::Sync). The recurring tick runs these on its own; the
# tasks are for operators. USERNAME picks the account (default: the allowed one), as in import.rake.
namespace :sync do
  desc "Show synchronisation health and per-period status for the linked account"
  task status: :environment do
    user = import_user
    health = HistoryImport::SyncHealth.for(user)
    puts JSON.pretty_generate(health)
    HistoryImport::SyncStatus.for(user).each do |m|
      puts format("%s..%s  %-13s verified %s  count %s/%s  disputes %d, suspected %d, pending removals %d",
                  m.from.utc.iso8601, m.to.utc.iso8601, m.status, m.last_verified_at&.utc&.iso8601 || "never",
                  m.present_count, m.remote_count || "-", m.open_disputes, m.suspected_removals, m.pending_removals)
    end
  end

  desc "Start one synchronisation now: KIND=sync (default), catch_up or reconcile"
  task run: :environment do
    run = HistoryImport::Sync.start!(import_user, kind: ENV.fetch("KIND", "sync"))
    puts "Started #{run.kind} run #{run.id}."
  rescue HistoryImport::Sync::Busy, HistoryImport::Sync::NotEligible, ArgumentError => e
    abort e.message
  end

  desc "Run the recurring tick once: start whatever is due for every eligible account"
  task tick: :environment do
    puts HistoryImport::Sync.tick!.to_json
  end

  desc "Allow synchronisation again after it stopped for an account problem that has been fixed"
  task resume: :environment do
    puts HistoryImport::Sync.resume!(import_user) ? "Synchronisation resumed." : "Nothing to resume."
  end
end
