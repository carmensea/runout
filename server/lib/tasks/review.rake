# Command-line review of reconciliation items (HistoryImport::Review). Read-only tasks: list, show.
# Decisions refuse while history storage is off, and are safe to repeat. Items are named
# removal:<id> or dispute:<id>. USERNAME picks the account, as for the import tasks.
namespace :review do
  def review_user
    username = ENV["USERNAME"].presence || Array(Rails.configuration.x.lastfm_allowed_usernames).first
    identity = Identity.find_by(provider: Identity::LASTFM, uid: Lastfm::AccountPolicy.normalize(username)) if username
    identity&.user || abort("No linked Last.fm account#{" for #{username}" if username}.")
  end

  def review_item(user)
    kind, id = ENV.fetch("ITEM") { abort("Set ITEM=removal:<id> or ITEM=dispute:<id>.") }.split(":", 2)
    model = { "removal" => ScrobbleRemoval, "dispute" => ReconciliationDispute }.fetch(kind) { abort("Unknown item kind #{kind}.") }
    model.find_by(id: id, user: user) || abort("No #{kind} #{id} for this account.")
  end

  def describe_play(scrobble)
    v = scrobble.name_variant
    "#{scrobble.played_at.utc.iso8601} slot #{scrobble.seq}: #{v.artist_name.inspect} - #{v.track_name.inspect} (#{v.album_name.inspect})" \
      "#{' [removed]' if scrobble.removed_at}"
  end

  def describe_variant(v) = "#{v.artist_name.inspect} - #{v.track_name.inspect} (#{v.album_name.inspect})"

  def decide
    result = yield
    puts(result == :already ? "Already decided; nothing changed." : "Done: #{result}.")
  rescue HistoryImport::Review::Invalid => e
    abort e.message
  end

  desc "List unresolved disputes and removals"
  task list: :environment do
    pending = HistoryImport::Review.pending(review_user)
    puts "Disputes (#{pending[:disputes].size}):"
    pending[:disputes].each do |d|
      puts "  dispute:#{d.id}  #{d.played_at.utc.iso8601}  #{d.stored_scrobble_ids.size} stored vs #{d.proposed_variant_ids.size} on Last.fm"
    end
    puts "Removals (#{pending[:removals].size}):"
    pending[:removals].each { |r| puts "  removal:#{r.id}  #{r.state.ljust(14)} #{describe_play(r.scrobble)}" }
  end

  desc "Show one item with its evidence: ITEM=removal:<id> or ITEM=dispute:<id>"
  task show: :environment do
    item = review_item(review_user)
    if item.is_a?(ReconciliationDispute)
      puts "dispute:#{item.id} (#{item.state}) at #{item.played_at.utc.iso8601}, first seen in fetch #{item.first_seen_fetch_id}, last in #{item.last_seen_fetch_id}"
      puts "Stored plays:"
      item.stored_scrobbles.each { |s| puts "  scrobble #{s.id}  #{describe_play(s)}" }
      puts "On Last.fm now (index: play):"
      item.proposed_variants.each_with_index { |v, i| puts "  #{i}: #{describe_variant(v)}" }
      puts "Resolve with PAIRS=\"<scrobble id>:<index>,...\" (unpaired Last.fm plays are added; unpaired stored plays become suspected removals), or dismiss."
    else
      puts "removal:#{item.id} (#{item.state})  #{describe_play(item.scrobble)}"
      puts "  first missing in fetch #{item.first_missing_fetch_id}#{", confirmed by fetch #{item.confirming_fetch_id}" if item.confirming_fetch_id}"
    end
    ReviewDecision.where(subject_type: item.class.name, subject_id: item.id).order(:id).each do |decision|
      puts "  #{decision.created_at.utc.iso8601}  #{decision.action} (#{decision.source})"
    end
  end

  desc "Approve a removal pending review: ITEM=removal:<id> [NOTE=...]"
  task approve: :environment do
    user = review_user
    decide { HistoryImport::Review.approve_removal!(review_item(user), by: user, note: ENV["NOTE"]) }
  end

  desc "Dismiss a removal or a dispute (keep the stored plays): ITEM=... [NOTE=...]"
  task dismiss: :environment do
    user = review_user
    item = review_item(user)
    decide do
      item.is_a?(ReconciliationDispute) ? HistoryImport::Review.dismiss_dispute!(item, by: user, note: ENV["NOTE"]) : HistoryImport::Review.dismiss_removal!(item, by: user, note: ENV["NOTE"])
    end
  end

  desc "Restore a removed play that reappeared on Last.fm, or KEEP=1 to keep it removed: ITEM=removal:<id>"
  task restore: :environment do
    user = review_user
    item = review_item(user)
    decide do
      ENV["KEEP"] == "1" ? HistoryImport::Review.keep_removed!(item, by: user, note: ENV["NOTE"]) : HistoryImport::Review.restore_reappeared!(item, by: user, note: ENV["NOTE"])
    end
  end

  desc "Resolve a dispute: ITEM=dispute:<id> PAIRS=\"<scrobble id>:<index>,...\" (empty: all new)"
  task resolve: :environment do
    user = review_user
    pairs = ENV["PAIRS"].to_s.split(",").map { |pair| pair.split(":", 2) }
    decide { HistoryImport::Review.resolve_dispute!(review_item(user), by: user, pairs: pairs, note: ENV["NOTE"]) }
  end
end

namespace :import do
  desc "Check committed months against Last.fm again and reconcile them: FROM=YYYY-MM-DD TO=YYYY-MM-DD (optional)"
  task recheck: :environment do
    user = import_user
    from = ENV["FROM"].presence && Time.zone.parse(ENV["FROM"])
    to = ENV["TO"].presence && Time.zone.parse(ENV["TO"])
    run = HistoryImport::Recheck.request!(user, from: from, to: to)
    puts run ? "Check run #{run.id} started for #{run.import_windows.count} months." : "No committed months in that range."
  rescue HistoryImport::Recheck::Busy => e
    abort e.message
  end

  desc "Show coverage, synchronisation and review status per imported month"
  task sync_status: :environment do
    HistoryImport::SyncStatus.for(import_user).each do |m|
      puts format("%s  %-13s checked %s  disputes %d, suspected %d, pending removals %d, reappeared %d, plays %d (recorded %d)",
                  m.from.to_date, m.status, m.last_checked_at&.utc&.iso8601 || "never", m.open_disputes,
                  m.suspected_removals, m.pending_removals, m.reappeared, m.present_count, m.committed_count.to_i)
    end
  end
end
