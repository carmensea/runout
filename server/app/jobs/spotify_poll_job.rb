# The recurring Spotify tick (docs/spotify-plan.md §10): queues one poll per connected, unpaused
# Spotify account. Does nothing while SPOTIFY_INGESTION_ENABLED is off.
class SpotifyPollJob < ApplicationJob
  queue_as :default

  limits_concurrency to: 1, key: "spotify-poll-tick", duration: 5.minutes, on_conflict: :discard

  def perform
    return unless ListeningStorage.enabled?("spotify")

    ListeningSource.spotify.active.where(paused_at: nil).pluck(:id).each { |id| SpotifyPollSourceJob.perform_later(id) }
  end
end
