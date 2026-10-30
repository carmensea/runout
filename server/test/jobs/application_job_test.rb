require "test_helper"

class ApplicationJobTest < ActiveJob::TestCase
  class LastfmJob < ApplicationJob
    def perform(error_class, retry_after = nil)
      raise error_class.constantize.new("synthetic", retry_after: retry_after)
    end
  end

  test "a long Retry-After is a scheduled retry, not a blocked worker" do
    freeze_time do
      LastfmJob.perform_now("Lastfm::Error::RateLimited", 600.0)
      assert_enqueued_with(job: LastfmJob, at: 600.seconds.from_now)
    end
  end

  test "without Retry-After, retries back off polynomially" do
    freeze_time do
      LastfmJob.perform_now("Lastfm::Error::Temporary")
      assert_enqueued_with(job: LastfmJob, at: 3.seconds.from_now) # 1**4 + 2
    end
  end

  test "retries stop after the execution limit and the error surfaces" do
    job = LastfmJob.new("Lastfm::Error::Temporary")
    job.executions = ApplicationJob::MAX_LASTFM_EXECUTIONS - 1
    assert_raises(Lastfm::Error::Temporary) { job.perform_now }
    assert_no_enqueued_jobs
  end

  test "permanent Last.fm errors are not retried" do
    assert_raises(Lastfm::Error::InvalidSessionKey) { LastfmJob.perform_now("Lastfm::Error::InvalidSessionKey") }
    assert_no_enqueued_jobs
  end
end
