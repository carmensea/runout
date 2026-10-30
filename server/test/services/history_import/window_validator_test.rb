require "test_helper"

class HistoryImport::WindowValidatorTest < ActiveSupport::TestCase
  include HistoryHelpers

  MARCH = [ Time.utc(2014, 3, 1), Time.utc(2014, 4, 1) ].freeze
  Play = FakeRecentTracks::Play

  setup do
    @user = history_user
    @window = window(@user, from: MARCH[0], to: MARCH[1])
    @client = stub_client(**Lastfm::Client::BACKGROUND_OPTIONS)
  end

  def serve(count:, ending: Time.utc(2014, 3, 31, 23), **options)
    @fake = FakeRecentTracks.history(count: count, ending: ending, same_second_every: nil, **options).install(self)
  end

  def validate(window = @window, **options)
    HistoryImport::WindowValidator.new(window: window, client: @client, username: "listener", **options).call
  end

  def play(at, track = "Track", artist: "Artist")
    Play.new(played_at: at, artist: artist, track: track, album: "", artist_mbid: "", track_mbid: "", album_mbid: "")
  end

  def staged = ImportWindowRow.joins(:import_window_fetch).where(import_window_fetches: { import_window_id: @window.id })

  test "an empty window validates with nothing staged" do
    serve(count: 0)
    assert_equal :validated, validate.status
    assert_equal "validated", @window.reload.state
    assert_equal 0, staged.count
    assert_equal 2, @fake.requests, "two complete reads"
  end

  test "a single-page window validates and stages exact strings" do
    serve(count: 3)
    @fake.replace_at(0, artist: "  Sigur Rós ", track: "Hoppípolla")
    assert_equal :validated, validate.status
    assert_equal 3, staged.count
    assert staged.exists?(artist_name: "  Sigur Rós ", track_name: "Hoppípolla"), "strings kept exactly"
    w = @window.reload
    assert_equal [ 3, 3, nil ], [ w.expected_total, w.fetched_count, w.claim_token ]
    assert w.validated_at
  end

  test "a multi-page window reads every page of both snapshots" do
    serve(count: 450)
    assert_equal :validated, validate.status
    assert_equal 450, staged.count
    assert_equal 6, @fake.requests, "3 pages x 2 complete snapshots"
  end

  test "identical plays in the same second are staged as separate occurrences" do
    serve(count: 0)
    at = Time.utc(2014, 3, 15, 20)
    3.times { @fake.add(play(at, "Same")) }
    @fake.add(play(at, "Other"))
    assert_equal :validated, validate.status
    assert_equal [ 0, 1, 2 ], staged.where(track_name: "Same").order(:occurrence).pluck(:occurrence)
    assert_equal 4, staged.where(played_at: at).count
  end

  test "a change of order between reads is not a difference" do
    serve(count: 0)
    at = Time.utc(2014, 3, 15, 20)
    %w[A B C D].each { |t| @fake.add(play(at, t)) }
    @fake.shuffle_same_second = true
    assert_equal :validated, validate.status
    assert_equal 4, staged.count
    assert_equal 0, @window.fetches.where(outcome: "mismatch").count
  end

  test "a play added during paging makes that read inconsistent; a stable re-read validates" do
    serve(count: 450)
    @fake.before_request = ->(n, fake) { fake.add(play(Time.utc(2014, 3, 31, 23, 30), "Late")) if n == 2 }
    assert_equal :validated, validate.status
    assert_equal 451, staged.count
    assert_equal 1, @window.fetches.where(outcome: "mismatch").where("error_message LIKE ?", "%reported%").count
  end

  test "a play removed during paging is detected the same way" do
    serve(count: 450)
    @fake.before_request = ->(n, fake) { fake.remove_if { |p| p.track == "Track 10" } if n == 2 }
    assert_equal :validated, validate.status
    assert_equal 449, staged.count
  end

  test "the same total with different contents between reads is a mismatch, not a match" do
    serve(count: 5)
    # After the first complete read (1 request), rename one play: totals stay identical.
    @fake.before_request = ->(n, fake) { fake.replace_at(2, track: "Renamed") if n == 2 }
    assert_equal :validated, validate.status
    mismatch = @window.fetches.where(outcome: "mismatch").sole
    assert_includes mismatch.error_message, '"only_in_first":1'
    assert staged.exists?(track_name: "Renamed")
    assert_not staged.exists?(track_name: "Track 2")
  end

  test "a window that keeps changing goes to review and is never marked validated" do
    serve(count: 5)
    @fake.before_request = ->(n, fake) { fake.replace_at(0, track: "Version #{n}") }
    result = validate
    assert_equal :needs_review, result.status
    assert_equal "needs_review", @window.reload.state
    assert_nil @window.validated_at
    assert_equal 0, staged.count, "nothing is staged for an unsettled window"
    assert_equal 4, @window.fetches.count
  end

  test "an API failure partway through fails the window, keeps the details, and a later run resumes" do
    serve(count: 450)
    @fake.fail_requests = { 2 => { status: 502, body: "Bad Gateway" }, 3 => { status: 502, body: "Bad Gateway" } }
    result = validate
    assert_equal :failed, result.status
    w = @window.reload
    assert_equal [ "failed", 502 ], [ w.state, w.last_http_status ]
    assert_nil w.validated_at
    assert_equal 0, staged.count
    assert_equal "failed", w.fetches.sole.outcome

    @fake.fail_requests = {}
    assert_equal :validated, validate.status
    assert_equal 450, staged.count
  end

  test "an interrupted validation is taken over after its lease expires, discarding partial work" do
    serve(count: 3)
    crashed = SecureRandom.uuid
    past = 1.hour.ago
    assert @window.claim_for_validation!(crashed, now: past)
    partial = @window.fetches.create!(attempt: 1, started_at: past, outcome: "in_progress")
    partial.rows.create!(played_at: MARCH[0] + 60, position: 0, occurrence: 0, variant_hash: NameVariant.hash_for({}), artist_name: "Half", track_name: "Fetched")
    @window.update_columns(state: "validating")

    assert_equal :validated, validate.status
    assert_equal "failed", partial.reload.outcome
    assert_includes partial.error_message, "interrupted"
    assert_not staged.exists?(artist_name: "Half"), "the interrupted fetch's rows are gone"
    assert_equal 3, staged.count
  end

  test "a live lease is never taken over" do
    serve(count: 3)
    assert @window.claim_for_validation!(SecureRandom.uuid)
    assert_equal :not_claimed, validate.status
    assert_equal 0, @fake.requests
  end

  test "a worker whose lease is taken over stops without writing a result" do
    serve(count: 3)
    newer = SecureRandom.uuid
    # While the first worker is fetching, its lease expires and another worker claims the window.
    @fake.before_request = ->(n, _fake) { ImportWindow.where(id: @window.id).update_all(claim_token: newer, lease_expires_at: 1.hour.from_now) if n == 1 }
    result = validate
    assert_equal :stale, result.status
    w = @window.reload
    assert_equal newer, w.claim_token
    assert_not_equal "validated", w.state
    assert_equal 0, staged.count
  end

  test "validated, committed, split and review windows are never re-validated" do
    serve(count: 3)
    %w[validated committed split needs_review].each do |state|
      @window.update_columns(state: state, validated_at: Time.current, committed_at: Time.current, committed_count: 0, claim_token: nil)
      assert_equal :not_claimed, validate.status, state
    end
    assert_equal 0, @fake.requests
  end

  test "a window over 20 pages is split into two non-overlapping halves" do
    serve(count: 4_100, ending: Time.utc(2014, 3, 31, 23))
    result = validate
    assert_equal :split, result.status
    assert_equal "split", @window.reload.state
    children = ImportWindow.where(parent_window: @window).order(:window_from)
    assert_equal [ [ MARCH[0], children.second.window_from ], [ children.first.window_to, MARCH[1] ] ],
                 children.map { |c| [ c.window_from, c.window_to ] }
    assert children.all? { |c| c.state == "pending" }
    assert_equal 1, @fake.requests, "the size is known from the first page"
  end

  test "undated or malformed rows send the window to review instead of being dropped" do
    serve(count: 3)
    @fake.fail_requests = { 1 => { status: 200, body: { recenttracks: { "@attr" => { page: "1", perPage: "200", totalPages: "1", total: "2" },
                                                                         track: [ { artist: { "#text" => "A" }, name: "T", date: { uts: "1394000000" } },
                                                                                  { artist: { "#text" => "A" }, name: "No date" } ] } }.to_json } }
    result = validate
    assert_equal :needs_review, result.status
    assert_includes result.detail, "without a date"
    assert_equal 0, staged.count
  end

  test "a window that keeps failing is left for review after the attempt limit" do
    serve(count: 3)
    @window.update_columns(attempts: HistoryImport::WindowValidator::MAX_WINDOW_ATTEMPTS, state: "failed")
    assert_equal :needs_review, validate.status
    assert_equal 0, @fake.requests
  end

  test "no Last.fm request is made inside a database transaction" do
    serve(count: 450)
    baseline = ActiveRecord::Base.connection.open_transactions
    depths = []
    @fake.before_request = ->(_n, _fake) { depths << ActiveRecord::Base.connection.open_transactions }
    validate
    assert_equal [ baseline ], depths.uniq
  end

  test "requests stay within the window's budget" do
    serve(count: 450)
    validate
    assert_operator @client.http_requests, :<=, HistoryImport::RequestBudget::MAX
  end
end

class HistoryImport::WindowValidatorFlagTest < ActiveSupport::TestCase
  test "with history storage disabled, nothing is fetched or written, staging included" do
    assert_not HistoryImport.enabled?
    user = User.create!(display_name: "listener")
    window = ImportWindow.new(user: user, window_from: Time.utc(2014, 3, 1), window_to: Time.utc(2014, 4, 1))
    fake = FakeRecentTracks.history(count: 3).install(self)
    validator = HistoryImport::WindowValidator.new(window: window, client: stub_client, username: "listener")
    assert_raises(HistoryImport::DisabledError) { validator.call }
    assert_raises(HistoryImport::DisabledError) { HistoryImport::WindowPlanner.plan!(user: user, from: Time.utc(2014, 1, 1), cutoff: Time.utc(2014, 4, 1)) }
    assert_equal 0, fake.requests
    assert_equal 0, ImportWindow.count + ImportWindowFetch.count + ImportWindowRow.count
  end
end
