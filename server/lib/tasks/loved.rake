namespace :loved do
  desc "Import the Last.fm loved list into loved_tracks, read-only towards Last.fm (needs LASTFM_LOVED_IMPORT_ENABLED=true for this command)"
  task import: :environment do
    users = User.joins(:identities).where(identities: { provider: Identity::LASTFM, revoked_at: nil }).distinct
    users = users.where(id: ENV["USER_ID"]) if ENV["USER_ID"].present?
    user = users.count == 1 ? users.first : abort("loved: expected one user with a Last.fm identity, found #{users.count} (set USER_ID)")
    report = Loved::Import.new(user: user).run!
    puts "Loved tracks listed by Last.fm: #{report.listed} (malformed entries: #{report.malformed})"
    puts "Added #{report.added}, kept #{report.kept}, loved again #{report.reloved}, no longer listed #{report.unloved}, left alone (manual) #{report.manual_skipped}"
    puts "Catalogue: #{report.linked} linked to a track, #{report.review} held for review, #{report.unlinked} without a link"
  end
end
