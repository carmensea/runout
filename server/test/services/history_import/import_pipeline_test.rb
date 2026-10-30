require "test_helper"

# Fetch, validate and commit a window end to end against the fake Last.fm, and check that the
# window's request budget counts every HTTP attempt across client retries, worker restarts and
# job retries. Synthetic data only.
class HistoryImport::ImportPipelineTest < ActiveSupport::TestCase
  include HistoryHelpers

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze

  setup do
    @user = history_user
    @window = window(@user, from: MARCH[0], to: MARCH[1])
  end

  def serve(count, **options)
    @fake = FakeRecentTracks.history(count: count, ending: Time.utc(2014, 3, 31, 23), same_second_every: 25, **options).install(self)
  end

  # Each run gets a fresh client, as a new job execution or another process would.
  def validate
    HistoryImport::WindowValidator.new(window: @window, client: stub_client(**Lastfm::Client::BACKGROUND_OPTIONS), username: "listener").call
  end

  def bad_gateway = { status: 502, body: "" }

  test "a fetched and validated window commits exactly what Last.fm returned" do
    serve(450)
    assert_equal :validated, validate.status
    assert_equal :committed, HistoryImport::WindowCommitter.new(window: @window).call.status
    assert_equal 450, Scrobble.where(user: @user).count
    expected = @fake.plays.map { |p| [ p.played_at.to_i, p.artist, p.track ] }.tally
    actual = Scrobble.where(user: @user).includes(:name_variant).map { |s| [ s.played_at.to_i, s.name_variant.artist_name, s.name_variant.track_name ] }.tally
    assert_equal expected, actual, "the same multiset of plays, same-second pairs included"
    assert_equal @fake.requests, @window.reload.http_requests_used
  end

  test "client retries count as separate requests" do
    serve(3)
    @fake.fail_requests = { 1 => bad_gateway }
    assert_equal :validated, validate.status
    assert_equal 3, @fake.requests, "one retried page plus two complete reads"
    assert_equal 3, @window.reload.http_requests_used
  end

  test "requests from failed runs and job retries accumulate on the window" do
    serve(3)
    @fake.fail_requests = { 1 => bad_gateway, 2 => bad_gateway, 3 => bad_gateway, 4 => bad_gateway }
    assert_equal :failed, validate.status, "the client gives up after 2 attempts"
    assert_equal 2, @window.reload.http_requests_used
    assert_equal :failed, validate.status, "a retry of the job: a new run on a new client"
    assert_equal 4, @window.reload.http_requests_used
    assert_equal :validated, validate.status
    assert_equal 6, @window.reload.http_requests_used
    assert_equal @fake.requests, @window.http_requests_used
  end

  test "requests of a worker that lost its lease still count" do
    serve(3)
    @fake.before_request = ->(n, _fake) { ImportWindow.where(id: @window.id).update_all(claim_token: SecureRandom.uuid) if n == 1 }
    assert_equal :stale, validate.status
    assert_equal @fake.requests, @window.reload.http_requests_used
  end

  test "a window that has used up its lifetime budget goes to review instead of fetching on" do
    serve(3) # one page: 16 requests per run, 32 over the window's life
    @window.update_columns(http_requests_used: 31)
    result = validate
    assert_equal :needs_review, result.status
    assert_match "used up across attempts", result.detail
    assert_equal 1, @fake.requests, "the second read would exceed the lifetime budget"
    assert_equal 32, @window.reload.http_requests_used
  end
end
