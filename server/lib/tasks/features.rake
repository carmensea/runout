# Per-account feature flags (User::FEATURES). Run over railway ssh in production. The display name
# is checked against the id so a mistyped id cannot reach someone else's account (as auth.rake).
namespace :features do
  desc "Let an account see a feature. Arguments: user UUID, display name, feature (memories)"
  task :grant, [ :user_id, :display_name, :feature ] => :environment do |_t, args|
    user, feature = feature_args!(args)
    user.update!(features: (user.features | [ feature ]))
    puts "#{user.display_name}: #{user.features.join(', ')}"
  end

  desc "Take a feature away from an account. Arguments: user UUID, display name, feature"
  task :revoke, [ :user_id, :display_name, :feature ] => :environment do |_t, args|
    user, feature = feature_args!(args)
    user.update!(features: user.features - [ feature ])
    puts "#{user.display_name}: #{user.features.presence&.join(', ') || 'none'}"
  end

  desc "Accounts with any feature on"
  task list: :environment do
    User.where.not(features: []).order(:created_at).each { |u| puts "#{u.id}  #{u.display_name}: #{u.features.join(', ')}" }
  end

  def feature_args!(args)
    user = User.find_by(id: args[:user_id].to_s) or abort "features: no user with id #{args[:user_id].inspect}"
    abort "features: display name does not match" unless user.display_name == args[:display_name].to_s
    feature = args[:feature].to_s
    abort "features: unknown feature #{feature.inspect}; one of #{User::FEATURES.join(', ')}" unless User::FEATURES.include?(feature)
    [ user, feature ]
  end
end
