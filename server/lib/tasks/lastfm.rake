namespace :lastfm do
  # Explicit relink after a Last.fm username change (docs/backend-plan.md §2).
  #
  #   1. Set LASTFM_ALLOWED_USERNAME to the new username and restart the server.
  #   2. bin/rails "lastfm:relink[old_name,new_name]"
  #   3. Sign in with Last.fm as the new username.
  #
  # The task checks that the new username's public profile has the same registration time as the
  # linked account, re-points the lookup key, and marks the link revoked so that step 3 (a real
  # authentication as the new username) is required before anything works again. It never merges
  # users, moves history or deletes data.
  desc "Relink a Last.fm account after a username change: lastfm:relink[old_name,new_name]"
  task :relink, [ :old_name, :new_name ] => :environment do |_task, args|
    old_uid = Lastfm::AccountPolicy.normalize(args[:old_name])
    new_uid = Lastfm::AccountPolicy.normalize(args[:new_name])
    abort "Usage: bin/rails \"lastfm:relink[old_name,new_name]\"" if old_uid.empty? || new_uid.empty?

    identity = Identity.find_by(provider: Identity::LASTFM, uid: old_uid)
    abort "No linked Last.fm account named #{args[:old_name]}. Nothing changed." unless identity
    unless Lastfm::AccountPolicy.allowed?(new_uid)
      abort "#{args[:new_name]} is not in LASTFM_ALLOWED_USERNAME. Update it first. Nothing changed."
    end
    if Identity.where(provider: Identity::LASTFM, uid: new_uid).where.not(id: identity.id).exists?
      abort "#{args[:new_name]} is already linked to a different Runout user. Nothing changed."
    end

    profile = Lastfm::Config.client.public_user_info(args[:new_name])
    if identity.registered_at.nil? || profile[:registered_at].nil? ||
       identity.registered_at.to_i != profile[:registered_at].to_i
      abort "#{args[:new_name]}'s registration time does not match the linked account, so it may be a " \
            "different Last.fm account. Nothing changed."
    end

    identity.update!(uid: new_uid, username: profile[:username], profile_url: profile[:profile_url],
                     credentials: nil, revoked_at: Time.current)
    puts "Relinked. Sign in with Last.fm as #{profile[:username]} to finish; until then the account shows as not connected."
  end

  # Read-only verification of user.getRecentTracks (docs/milestone-2-plan.md §3). Stores nothing,
  # prints only booleans and counts, uses at most 20 paced requests.
  # Allowed before Last.fm answers the storage question (plan §2, decision 4).
  desc "Verify Last.fm recent-tracks behaviour, read-only (no data stored)"
  task probe: :environment do
    username = Lastfm::AccountPolicy.allowed_usernames.first
    abort "Set LASTFM_ALLOWED_USERNAME first." unless username

    identity = Identity.find_by(provider: Identity::LASTFM, uid: username, revoked_at: nil)
    findings = Lastfm::ApiProbe.new(client: Lastfm::Config.client, username: username,
                                    session_key: identity&.session_key).run
    puts JSON.pretty_generate(findings)
  end
end

namespace :runout do
  desc "Report the on-disk size of data derived from Last.fm (read-only)"
  task storage_report: :environment do
    report = StorageReport.rows
    report.each { |row| puts format("%-24s %10d rows %12s", row.table, row.rows, ActiveSupport::NumberHelper.number_to_human_size(row.bytes)) }
    puts format("%-24s %16s %12s", "total", "", ActiveSupport::NumberHelper.number_to_human_size(StorageReport.total_bytes(report)))
  end
end
