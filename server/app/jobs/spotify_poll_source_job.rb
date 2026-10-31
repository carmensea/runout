# One poll of one Spotify account (Spotify::Poller). Solid Queue runs at most one per account, and
# the poller's own advisory lock covers anything that bypasses the queue.
class SpotifyPollSourceJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: ->(source_id, **) { "spotify-poll-#{source_id}" }, duration: 10.minutes, on_conflict: :discard

  def perform(source_id, trigger: "schedule", force: false)
    source = ListeningSource.spotify.find_by(id: source_id) or return
    result = Spotify::Poller.new.poll!(source, trigger: trigger, force: force)
    Rails.logger.info("SpotifyPollSourceJob #{source_id}: #{result.status} #{result.poll&.recorded.to_json}")
  end
end
