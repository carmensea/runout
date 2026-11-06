# The recurring ListenBrainz tick: one poll per connected, unpaused ListenBrainz account, spread
# across the tick like the Spotify one. Does nothing while LISTENBRAINZ_INGESTION_ENABLED is off.
class ListenbrainzPollJob < ApplicationJob
  queue_as :default

  TICK = 10.minutes

  limits_concurrency to: 1, key: "listenbrainz-poll-tick", duration: TICK, on_conflict: :discard

  def perform
    return unless ListeningStorage.enabled?("listenbrainz")

    ids = ListeningSource.where(provider: "listenbrainz", state: "connected", paused_at: nil).order(:id).pluck(:id)
    ids.each_with_index { |id, i| ListenbrainzPollSourceJob.set(wait: TICK * i / ids.size).perform_later(id) }
  end
end
