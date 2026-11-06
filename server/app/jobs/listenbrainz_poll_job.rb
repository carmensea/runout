# The recurring ListenBrainz tick: one poll per connected, unpaused ListenBrainz account, spread
# across the tick like the Spotify one, and one backfill run for each account with history left. Does nothing while LISTENBRAINZ_INGESTION_ENABLED is off.
class ListenbrainzPollJob < ApplicationJob
  queue_as :default

  TICK = 10.minutes

  limits_concurrency to: 1, key: "listenbrainz-poll-tick", duration: TICK, on_conflict: :discard

  def perform
    return unless ListeningStorage.enabled?("listenbrainz")

    sources = ListeningSource.where(provider: "listenbrainz", state: "connected", paused_at: nil).order(:id)
    ids = sources.pluck(:id)
    ids.each_with_index { |id, i| ListenbrainzPollSourceJob.set(wait: TICK * i / ids.size).perform_later(id) }
    # History still to read (Listenbrainz::Backfill): one bounded run per account per tick, after its poll.
    todo = sources.where.not(covered_from: nil).where("backfill_state IS NULL OR backfill_state <> 'done'").pluck(:id)
    todo.each_with_index { |id, i| ListenbrainzBackfillJob.set(wait: TICK * i / todo.size + 1.minute).perform_later(id) }
  end
end
