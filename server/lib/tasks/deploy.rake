namespace :deploy do
  desc "Production only: prepare the databases at container start (docs/railway-deployment.md)"
  task release: :environment do
    abort "deploy:release runs only in production" unless Rails.env.production?

    fresh = DatabaseRelease.check!
    Rake::Task["db:prepare"].invoke
    # A restored archive arrives marked "development", which would disarm Rails' production guards.
    Rake::Task["db:environment:set"].invoke
    Rake::Task["taxonomy:seed"].invoke if fresh
  end
end
