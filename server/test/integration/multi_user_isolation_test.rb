require "test_helper"

# Multi-user readiness (docs/multi-user-plan.md §1, PR 1): two accounts, one with the Last.fm
# archive, a Spotify source, a passkey and plays; the other invited without any provider and
# empty. Every endpoint answers each account with its own data only; deleting one leaves the
# other untouched; nothing a user can do changes the shared catalogue.
class MultiUserIsolationTest < ActionDispatch::IntegrationTest
  include HistoryHelpers

  setup do
    @flag = Rails.configuration.x.passkeys_enabled
    Rails.configuration.x.passkeys_enabled = "true"
  end
  teardown { Rails.configuration.x.passkeys_enabled = @flag }

  def json = response.parsed_body

  def post_json(path, body = {})
    post path, params: body.to_json, headers: same_origin_headers.merge("Content-Type" => "application/json")
  end

  # An account the operator invited: no Last.fm, no Spotify, no plays. Signed in with its own session.
  def invite!(name, timezone: "America/Los_Angeles")
    user = User.create!(display_name: name, reporting_timezone: timezone)
    _, token = Session.start!(user: user, ip_address: "127.0.0.1", user_agent: "test")
    [ user, token ]
  end

  def as(token)
    cookies[Authentication::COOKIE_NAME] = token
  end

  # The owner-like account: Last.fm signed in, three plays, a Spotify source with one observation,
  # a passkey, a review item and a loved track.
  def seed_alice!
    sign_in_via_lastfm(username: "listener")
    alice = User.sole
    token = session_cookie
    v1 = variant(track: "Song One", artist: "Band")
    v2 = variant(track: "Song Two", artist: "Band")
    scrobble(alice, at: Time.utc(2014, 3, 15, 20), variant: v1)
    scrobble(alice, at: Time.utc(2014, 3, 15, 20), seq: 1, variant: v1)
    scrobble(alice, at: Time.utc(2016, 3, 15, 9), variant: v2)
    source = ListeningSource.create!(user: alice, provider: "spotify", external_account_id: "alice-spotify", display_name: "Alice",
                                     state: "connected", connected_at: Time.current, scopes: "user-read-recently-played")
    play = alice.scrobbles.first
    observation = ListeningObservation.create!(user: alice, listening_source: source, provider: "spotify", source_event_id: "e1",
                                               reported_at: play.played_at, reported_at_raw: play.played_at.iso8601(3), timestamp_kind: "spotify_played_at",
                                               name_variant: v1, link_state: "pending_review", received_at: Time.current, last_seen_at: Time.current)
    passkey = WebauthnCredential.create!(user: alice, external_id: "cred-alice", public_key: "pk", nickname: "Laptop")
    w = window(alice, from: Time.utc(2014, 3, 1), to: Time.utc(2014, 4, 1), state: "committed", validated_at: Time.current, committed_at: Time.current, committed_count: 2)
    f = fetch(w, outcome: "validated")
    removal = ScrobbleRemoval.create!(user: alice, scrobble: play, first_missing_fetch: f, confirming_fetch: f, state: "pending_review")
    LovedTrack.create!(user: alice, name_variant: v1, source: "lastfm", loved_at: Time.current)
    { user: alice, token: token, source: source, observation: observation, passkey: passkey, removal: removal, session: Session.sole }
  end

  READS = %w[/api/connection /api/overview /api/search?q=song /api/calendar /api/plays /api/on-this-day?date=2014-03-15
             /api/genres/rock /api/loved-tracks /api/import /api/sync /api/reviews /api/listening-sources
             /api/listening-sources/reviews /api/passkeys /api/sessions /api/session].freeze

  test "an invited account without any provider gets its own, empty answers from every endpoint" do
    a = seed_alice!
    bob, bob_token = invite!("bob")
    as bob_token

    get "/api/connection"
    assert_equal({ "status" => "none", "displayName" => "bob", "timezone" => "America/Los_Angeles", "theme" => nil, "features" => [] }, json)
    get "/api/session"
    assert_equal({ "signedIn" => true, "user" => { "displayName" => "bob", "timezone" => "America/Los_Angeles" },
                   "methods" => { "passkeys" => 0, "recoveryCodes" => 0, "lastfm" => false } }, json)

    # The archive waits for stored plays (409), never showing another account's.
    %w[/api/overview /api/search?q=song /api/calendar /api/plays /api/on-this-day?date=2014-03-15 /api/genres/rock /api/loved-tracks].each do |path|
      get path
      assert_response :conflict, path
    end

    get "/api/import"
    assert_response :ok
    assert_equal({ "plays" => 0, "firstPlayedAt" => nil, "lastPlayedAt" => nil, "sources" => {} }, json["stored"])
    assert_equal 0, json["importedScrobbles"]
    get "/api/sync"
    assert_response :ok
    assert_equal 0, json["attention"]["total"]
    assert_nil json["connectionState"]
    get "/api/reviews"
    assert_equal 0, json["total"]
    get "/api/listening-sources"
    assert_equal "not_connected", json.dig("spotify", "state")
    assert_equal false, json.dig("lastfm", "connected")
    get "/api/listening-sources/reviews"
    assert_equal [], json["items"]
    get "/api/passkeys"
    assert_equal [], json["passkeys"]
    get "/api/sessions"
    assert_equal 1, json["sessions"].size, "bob sees only his own browser"
    assert_equal 1, Session.where(user: bob).count

    # Alice's rows, by id, are 404 for Bob on every write.
    post_json "/api/reviews/removal/#{a[:removal].id}/approve", { version: "v", confirm: true }
    assert_response :not_found
    post_json "/api/listening-sources/reviews/#{a[:observation].id}/link"
    assert_response :not_found
    delete "/api/passkeys/#{a[:passkey].id}", headers: same_origin_headers
    assert_response :not_found
    delete "/api/sessions/#{a[:session].id}", headers: same_origin_headers
    assert_response :not_found
    assert_equal "pending_review", a[:observation].reload.link_state
    assert_nil a[:passkey].reload.revoked_at
    assert Session.exists?(a[:session].id)

    # Alice still sees everything of hers, and nothing changed.
    as a[:token]
    get "/api/overview"
    assert_response :ok
    get "/api/import"
    assert_equal({ "plays" => 3, "sources" => { "lastfm" => 3 } }, json["stored"].slice("plays", "sources"))
    get "/api/listening-sources"
    assert_equal "connected", json.dig("spotify", "state")
    assert_equal 1, json.dig("spotify", "pendingReview")
    get "/api/sessions"
    assert_equal 1, json["sessions"].size
  end

  test "preferences and the theme are per account" do
    a = seed_alice!
    _, bob_token = invite!("bob")
    as bob_token
    patch "/api/account", params: { theme: "moss" }, headers: same_origin_headers, as: :json
    assert_response :ok
    as a[:token]
    get "/api/connection"
    assert_nil json["theme"], "alice's theme is untouched"
  end

  test "small archives answer in shape: one play, then three" do
    bob, bob_token = invite!("bob")
    as bob_token
    scrobble(bob, at: Time.utc(2026, 1, 2, 3), variant: variant(track: "Only", artist: "Solo"))
    get "/api/overview"
    assert_response :ok
    get "/api/import"
    assert_equal({ "plays" => 1, "sources" => { "lastfm" => 1 } }, json["stored"].slice("plays", "sources"))
    get "/api/search", params: { q: "only" }
    assert_equal [ "Only" ], json["tracks"].map { |t| t["name"] }
    scrobble(bob, at: Time.utc(2026, 1, 2, 4), variant: variant(track: "Two", artist: "Solo"))
    scrobble(bob, at: Time.utc(2026, 1, 2, 5), variant: variant(track: "Three", artist: "Solo"))
    get "/api/plays", params: { period: "all" }
    assert_equal 3, json["total"]
  end

  test "deleting one account leaves the other's data in every table" do
    a = seed_alice!
    bob, bob_token = invite!("bob")
    as bob_token
    v = variant(track: "Bob Song", artist: "Bob Band")
    scrobble(bob, at: Time.utc(2026, 2, 2, 2), variant: v)
    ListeningSource.create!(user: bob, provider: "spotify", external_account_id: "bob-spotify", display_name: "Bob",
                            state: "connected", connected_at: Time.current, scopes: "user-read-recently-played")
    WebauthnCredential.create!(user: bob, external_id: "cred-bob", public_key: "pk", nickname: "Phone")
    RecoveryCode.regenerate!(bob)
    before = per_user_counts(a[:user])

    delete "/api/account", params: { confirm_name: "bob" }, headers: same_origin_headers, as: :json
    assert_response :ok
    assert_not User.exists?(bob.id)
    assert_equal 0, Scrobble.where(user_id: bob.id).count
    assert_equal 0, ListeningSource.where(user_id: bob.id).count
    assert_equal 0, WebauthnCredential.where(user_id: bob.id).count
    assert_equal 0, RecoveryCode.where(user_id: bob.id).count
    assert_equal 0, Session.where(user_id: bob.id).count
    assert_equal before, per_user_counts(a[:user]), "alice's rows are exactly as they were"
    assert NameVariant.exists?(v.id), "the shared catalogue keeps the variant; only plays are per user"
  end

  test "a signed-in account cannot change the shared catalogue through the API" do
    a = seed_alice!
    bob, bob_token = invite!("bob")
    scrobble(bob, at: Time.utc(2026, 2, 2, 2), variant: variant(track: "Song One", artist: "Band"))
    links = -> { [ NameVariant.order(:id).pluck(:id, :artist_id, :album_id, :track_id, :track_match), Track.order(:id).pluck(:id, :merged_into_id, :title),
                   Artist.order(:id).pluck(:id, :merged_into_id, :name) ] }
    before = links.call
    as bob_token
    post_json "/api/reviews/removal/#{a[:removal].id}/approve", { version: "v", confirm: true }
    post_json "/api/reviews/dispute/1/accept", { version: "v", confirm: true }
    post_json "/api/listening-sources/reviews/#{a[:observation].id}/separate"
    patch "/api/account", params: { theme: "verdant" }, headers: same_origin_headers, as: :json
    assert_equal before, links.call, "no route lets a signed-in account rewrite catalogue links or merges"
  end

  test "plays recorded through one account's Spotify source belong to that account only" do
    a = seed_alice!
    bob, _ = invite!("bob")
    flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    begin
      event = Spotify::Mapping.event(spotify_item(Time.utc(2026, 3, 3, 3), track: "New Play", artist: "Band"))
      Listening::Recorder.new(a[:source]).record!(event)
    ensure
      Rails.configuration.x.spotify_ingestion_enabled = flag
    end
    assert_equal 4, Scrobble.where(user: a[:user]).count
    assert_equal 0, Scrobble.where(user: bob).count
    assert_equal [ a[:user].id ], ListeningObservation.where(source_event_id: event.source_event_id).pluck(:user_id)
  end

  test "a lost Spotify permission counts as attention for its owner only" do
    a = seed_alice!
    _, bob_token = invite!("bob")
    a[:source].update!(state: "needs_reauth")
    as a[:token]
    get "/api/sync"
    assert_equal 1, json["attention"]["account"]
    as bob_token
    get "/api/sync"
    assert_equal 0, json["attention"]["total"]
  end

  private

  def per_user_counts(user)
    [ Scrobble, ListeningSource, ListeningObservation, WebauthnCredential, RecoveryCode, Session, LovedTrack, ScrobbleRemoval, Identity, LastfmConnection ]
      .to_h { |model| [ model.name, model.where(user_id: user.id).count ] }
  end
end
