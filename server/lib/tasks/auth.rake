namespace :auth do
  desc "Print a single-use 15-minute sign-in link for a user (emergency recovery; run over railway ssh). Arguments: user UUID, display name"
  task :recovery_link, [ :user_id, :display_name ] => :environment do |_t, args|
    abort "auth: RUNOUT_PASSKEYS_ENABLED is off; the link route would answer 404" unless Passkeys.enabled?
    user = User.find_by(id: args[:user_id]) or abort "auth: no user with id #{args[:user_id].inspect}"
    abort "auth: display name does not match" unless user.display_name == args[:display_name].to_s
    token = SignInLink.issue!(user)
    Rails.logger.warn("Operator sign-in link issued for user #{user.id}")
    puts "#{Rails.configuration.x.app_origin}/api/auth/link/#{token}"
    puts "Valid #{SignInLink::TTL.inspect}, single use. Sign in, then enrol a passkey and regenerate the recovery codes."
  end

  desc "Sign in as a person to see what they see (troubleshooting): a single-use 15-minute link opening an operator session, which shows memory text as placeholder words and cannot write memories. Arguments: user UUID, display name"
  task :sign_in_as, [ :user_id, :display_name ] => :environment do |_t, args|
    abort "auth: RUNOUT_PASSKEYS_ENABLED is off; the link route would answer 404" unless Passkeys.enabled?
    user = find_account!(args)
    token = SignInLink.issue!(user, kind: "operator")
    Rails.logger.warn("Operator sign-in-as link issued for user #{user.id}")
    puts "#{Rails.configuration.x.app_origin}/api/auth/link/#{token}"
    puts "Valid #{SignInLink::TTL.inspect}, single use. Open it in a private window: it signs that window in as #{user.display_name}. Their memories show as placeholder words and cannot be changed; the session is listed in their Settings as an operator sign-in. Sign out there when done."
  end

  desc "Invite a person: create their account and print a single-use 24-hour link (docs/multi-user-plan.md §3). Arguments: display name, IANA timezone"
  task :invite_link, [ :display_name, :timezone ] => :environment do |_t, args|
    abort "auth: RUNOUT_PASSKEYS_ENABLED is off; the invited person could not enrol a passkey" unless Passkeys.enabled?
    name = args[:display_name].to_s.strip
    abort "auth: a display name is required" if name.empty?
    tz = args[:timezone].to_s.strip
    abort "auth: unknown timezone #{tz.inspect}; use an IANA name such as America/Los_Angeles" unless User.timezones.include?(tz)

    # An invitation that expired unopened leaves an account with nothing in it: reuse it rather than
    # leave empties behind. Anything with a passkey or an identity is a real account, never reused.
    unfinished = User.where(display_name: name).left_joins(:webauthn_credentials, :identities)
                     .where(webauthn_credentials: { id: nil }, identities: { id: nil }).order(:created_at).first
    user = unfinished || User.create!(display_name: name, reporting_timezone: tz)
    user.update!(reporting_timezone: tz) if unfinished && user.reporting_timezone != tz
    token = SignInLink.issue!(user, kind: "invitation")
    Rails.logger.warn("Invitation link issued for user #{user.id}#{' (reusing an unfinished account)' if unfinished}")
    puts "#{Rails.configuration.x.app_origin}/api/auth/link/#{token}"
    puts "For #{name} (#{tz}). Valid 24 hours, single use. Opening it signs them in to add a passkey and save their recovery codes; after that the link is dead. If it expires first, run this task again with the same name."
  end

  # Finds the account by its immutable id and checks the display name, so a mistyped id can't
  # reach someone else's account.
  def find_account!(args)
    user = User.find_by(id: args[:user_id].to_s) or abort "auth: no user with id #{args[:user_id].inspect}"
    abort "auth: display name does not match" unless user.display_name == args[:display_name].to_s
    user
  end

  desc "Revoke a person's open invitation links (nothing else changes). Arguments: user UUID, display name"
  task :revoke_invitation, [ :user_id, :display_name ] => :environment do |_t, args|
    user = find_account!(args)
    revoked = SignInLink.where(user: user, kind: "invitation").where("expires_at > ?", Time.current).update_all(expires_at: Time.current)
    Rails.logger.warn("Invitation links revoked for user #{user.id}: #{revoked}")
    puts "Revoked #{revoked} open invitation link#{'s' unless revoked == 1} for #{user.display_name} (#{user.id})."
    unfinished = user.webauthn_credentials.active.none? && user.identities.none? && user.scrobbles.none? && user.listening_sources.none?
    puts(unfinished ? "The account is empty (no passkey, identity, source or play). To remove it: bin/rails \"auth:remove_account[#{user.id},#{user.display_name},DELETE #{user.id}]\"" : "The account is in use and stays.")
  end

  desc "Delete an invited account and everything stored for it. Arguments: user UUID, display name, and the confirmation 'DELETE <uuid>'"
  task :remove_account, [ :user_id, :display_name, :confirm ] => :environment do |_t, args|
    user = find_account!(args)
    abort "auth: this account signs in with Last.fm; it is deleted from its own Settings, never here" if user.identities.exists?
    counts = { plays: user.scrobbles.count, sources: user.listening_sources.count, passkeys: user.webauthn_credentials.count, sessions: user.sessions.count }
    expected = "DELETE #{user.id}"
    unless args[:confirm].to_s == expected
      abort "auth: not deleted. This would remove #{user.display_name} (#{user.id}) and #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}. " \
            "To confirm, pass the third argument exactly: #{expected}"
    end
    user.destroy!
    Rails.logger.warn("Account removed by the operator: #{user.id}")
    puts "Removed #{user.display_name} (#{user.id}) and #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}. Backups made before now still hold a copy until they age out."
  end
end
