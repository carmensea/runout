require "test_helper"

# Real concurrency (docs/spotify-plan.md §10): threads hold separate database connections, like
# separate Solid Queue workers. Committed data is needed, so no transactional wrapper; the test
# removes its own rows. Spotify is stubbed.
class Spotify::PollConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  T = Time.utc(2026, 11, 3, 12)

  setup do
    @flag = Rails.configuration.x.spotify_ingestion_enabled
    Rails.configuration.x.spotify_ingestion_enabled = "true"
    @tag = "conc#{SecureRandom.hex(4)}"
    @user = User.create!(display_name: @tag)
    @source = ListeningSource.create!(user: @user, provider: "spotify", external_account_id: @tag, connected_at: T,
                                      credentials: { "access_token" => "a", "refresh_token" => "r", "expires_at" => (T + 1.year).to_i })
  end

  teardown do
    @user.destroy! # cascades to sources, polls, observations and plays
    variants = NameVariant.where(artist_name: @tag)
    CatalogueReview.where(name_variant_id: variants.select(:id)).delete_all
    variants.delete_all
    Track.joins(:artist).where(artists: { name: @tag }).delete_all
    Album.joins(:artist).where(artists: { name: @tag }).delete_all
    Artist.where(name: @tag).delete_all
    Rails.configuration.x.spotify_ingestion_enabled = @flag
  end

  def poller = Spotify::Poller.new(account: Spotify::Account.new(clock: -> { T }), clock: -> { T })

  test "two workers polling one account at once: one polls, the other stands aside; nothing is recorded twice" do
    entered = Queue.new
    release = Queue.new
    body = { items: Array.new(5) { |i| spotify_item(T - (i + 1) * 240, track: "Song #{i}", artist: @tag) } }.to_json
    stub_request(:get, %r{api\.spotify\.com/v1/me/player/recently-played}).to_return do
      entered << true
      release.pop # hold the first poll inside its request
      { status: 200, body: body, headers: { "Content-Type" => "application/json" } }
    end
    first = Thread.new { ActiveRecord::Base.connection_pool.with_connection { poller.poll!(@source).status } }
    entered.pop
    second = Thread.new { ActiveRecord::Base.connection_pool.with_connection { poller.poll!(ListeningSource.find(@source.id)).status } }
    assert_equal :busy, second.value
    release << true
    assert_equal :ok, first.value
    assert_equal 5, Scrobble.where(user: @user).count
    assert_equal 1, ListeningPoll.where(listening_source_id: @source.id).count
  end

  test "two workers recording the same report at once store it once" do
    event = Spotify::Mapping.event(spotify_item(T, track: "Same", artist: @tag))
    go = Queue.new
    threads = Array.new(2) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          go.pop
          Listening::Recorder.new(ListeningSource.find(@source.id)).record!(event).outcome
        end
      end
    end
    2.times { go << true }
    assert_equal %i[created seen], threads.map(&:value).sort
    assert_equal 1, Scrobble.where(user: @user).count
    assert_equal 1, ListeningObservation.where(user_id: @user.id).count
  end
end
