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
end
