class ApplicationJob < ActiveJob::Base
  # Solid Queue keeps enqueued jobs in Postgres, so they survive restarts, but it does not retry a
  # job that raises: the job lands in solid_queue_failed_executions. Retries are declared here.

  # Last.fm temporary failures and rate limiting: back off and try again (about 1 hour in total).
  retry_on Lastfm::Error::Temporary, wait: :polynomially_longer, attempts: 8

  # A deadlock or lost connection is worth one more try.
  retry_on ActiveRecord::Deadlocked, ActiveRecord::ConnectionNotEstablished, wait: 5.seconds, attempts: 3

  # The record a job refers to was deleted (for example, the account): nothing left to do.
  discard_on ActiveJob::DeserializationError
end
