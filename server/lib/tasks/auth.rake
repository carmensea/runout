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
end
