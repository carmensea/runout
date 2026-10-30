# Operator tasks for the historical import (docs/milestone-2-plan.md §7). All of them refuse while
# history storage is off, except `status`, which only reads. USERNAME picks the account; by default
# it is the single linked Last.fm account.
namespace :import do
  def import_user
    username = ENV["USERNAME"].presence || Array(Rails.configuration.x.lastfm_allowed_usernames).first
    identity = Identity.find_by(provider: Identity::LASTFM, uid: Lastfm::AccountPolicy.normalize(username)) if username
    identity&.user || abort("No linked Last.fm account#{" for #{username}" if username}.")
  end

  def active_run(user) = ImportRun.active.find_by(user: user) || abort("No active import.")

  def orchestrator = HistoryImport::Orchestrator.new

  desc "Start (or continue) the historical import for the linked account"
  task start: :environment do
    run = orchestrator.start!(import_user)
    puts "Import run #{run.id}: #{run.state}"
  end

  desc "Show import progress (committed data only)"
  task status: :environment do
    progress = HistoryImport::Progress.for(import_user)
    progress.to_h.each { |key, value| puts format("%-20s %s", key, value.inspect) }
  end

  desc "Pause the active import (the window in progress finishes)"
  task pause: :environment do
    puts orchestrator.pause!(active_run(import_user)) ? "Paused." : "Nothing to pause."
  end

  desc "Resume a paused import (the account is verified again)"
  task resume: :environment do
    puts "Import run: #{orchestrator.resume!(active_run(import_user)).state}"
  end

  desc "Cancel the active import (committed history is kept)"
  task cancel: :environment do
    orchestrator.cancel!(active_run(import_user))
    puts "Cancelled."
  end

  desc "Retry stopped or reviewed windows: WINDOW=id for one, otherwise all"
  task retry: :environment do
    recovery = HistoryImport::Recovery.new
    if ENV["WINDOW"].present?
      retried = recovery.retry_window!(ImportWindow.find_by!(id: ENV["WINDOW"], user: import_user))
      puts retried ? "Retried window #{ENV['WINDOW']}." : "That window isn't stopped or awaiting review."
    else
      puts "Retried #{recovery.retry_all!(import_user)} windows."
    end
  end
end
