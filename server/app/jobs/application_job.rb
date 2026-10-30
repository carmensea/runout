class ApplicationJob < ActiveJob::Base
  # Solid Queue keeps enqueued jobs in Postgres, so they survive restarts, but it does not retry a
  # job that raises: the job lands in solid_queue_failed_executions. Retries are declared here.

  # Last.fm transient failures and rate limits (docs/milestone-2-plan.md §7.3, "Combined retry
  # budget"). The background client already retried once, briefly. The job then retries up to
  # MAX_LASTFM_EXECUTIONS times in total. Each retry is *scheduled*: the server's Retry-After when it
  # sent one, otherwise polynomial backoff. So no worker sleeps through a long delay, and an outage
  # costs at most 2 x 5 attempts per call.
  MAX_LASTFM_EXECUTIONS = 5

  rescue_from Lastfm::Error::Temporary do |error|
    raise error if executions >= MAX_LASTFM_EXECUTIONS

    retry_job(wait: (error.retry_after || ((executions**4) + 2)).seconds)
  end

  # A deadlock or lost connection is worth one more try.
  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: 5.seconds, attempts: 3

  # The record a job refers to was deleted (for example, the account): nothing left to do.
  discard_on ActiveJob::DeserializationError
end
