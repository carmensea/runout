# The recurring Spotify tick (docs/spotify-plan.md §10): queues one poll per connected, unpaused
# Spotify account, spread evenly across the tick so several accounts never hit Spotify in the same
# second (docs/multi-user-plan.md §1.3). Does nothing while SPOTIFY_INGESTION_ENABLED is off.
class SpotifyPollJob < ApplicationJob
  queue_as :default

  TICK = 5.minutes

  limits_concurrency to: 1, key: "spotify-poll-tick", duration: TICK, on_conflict: :discard

  def perform
    return unless ListeningStorage.enabled?("spotify")

    ids = ListeningSource.spotify.active.where(paused_at: nil).order(:id).pluck(:id)
    ids.each_with_index { |id, i| SpotifyPollSourceJob.set(wait: TICK * i / ids.size).perform_later(id) }
  end
end
