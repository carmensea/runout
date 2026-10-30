# Helpers for orchestration tests: a linked synthetic account, a synthetic history spread over a
# few months, and a way to run the job chain the way Solid Queue would (due jobs only, in order).
module ImportHelpers
  extend ActiveSupport::Concern
  include ActiveJob::TestHelper

  Play = FakeRecentTracks::Play

  # A Last.fm-linked user registered three months before the start of this month.
  def linked_user(name = "listener")
    user = User.create!(display_name: name)
    registered = Time.current.utc.beginning_of_month - 3.months + 5.days
    identity = Identity.create!(user: user, provider: Identity::LASTFM, uid: name, username: name, registered_at: registered,
                                credentials: { "session_key" => "sk-#{name}" })
    LastfmConnection.create!(user: user, identity: identity)
    user
  end

  # Plays in each month since registration: two pages in the oldest, an empty month, identical
  # same-second plays, and a few in the current (partial) month before now.
  def synthetic_history
    first = Time.current.utc.beginning_of_month - 3.months
    plays = Array.new(250) { |i| play(first + 6.days + (i * 600), "Old #{i % 40}", artist: "Artist #{i % 9}") }
    same = first + 2.months + 3.days
    plays += [ play(same, "Twice"), play(same, "Twice"), play(same, "Other"), play(same + 60, "Later") ]
    plays += Array.new(3) { |i| play(Time.current.utc.beginning_of_month + (i * 60), "Now #{i}") }
    plays.select { |p| p.played_at < Time.current }
  end

  def play(at, track, artist: "Artist")
    Play.new(played_at: at.utc.change(usec: 0), artist: artist, track: track, album: "", artist_mbid: "", track_mbid: "", album_mbid: "")
  end

  def serve_history(plays = synthetic_history, playcount: plays.size)
    @fake = FakeRecentTracks.new(plays).install(self)
    @playcount = playcount
    stub_account_check
    @fake
  end

  def stub_account_check(registered: nil, playcount: nil)
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including("method" => "user.getInfo")).to_return do |request|
      name = Rack::Utils.parse_query(request.uri.query)["sk"].to_s.delete_prefix("sk-")
      identity = Identity.find_by(uid: name)
      unixtime = (registered || identity&.registered_at).to_i
      { status: 200, body: { user: { name: name, playcount: (playcount || @playcount).to_s, registered: { unixtime: unixtime.to_s } } }.to_json }
    end
  end

  def orchestrator = HistoryImport::Orchestrator.new

  # Performs due jobs until none are left, like a worker would. Jobs scheduled for later stay
  # queued. Returns the number of jobs performed.
  def drain(limit: 300)
    performed = 0
    limit.times do
      due = enqueued_jobs.count { |job| job[:at].nil? || job[:at] <= Time.current.to_f }
      return performed if due.zero?

      performed += due
      perform_enqueued_jobs(at: Time.current)
    end
    flunk "the job chain didn't settle"
  end

  # Runs the chain through every scheduled retry, travelling forward in time between them.
  def drain_with_retries(rounds: 12)
    rounds.times do
      drain
      next_at = enqueued_jobs.filter_map { |job| job[:at] }.min
      return unless next_at

      travel_to(Time.zone.at(next_at) + 1.second)
    end
  end

  def run_for(user) = ImportRun.where(user: user).order(:created_at).last

  def committed_plays(user) = Scrobble.where(user: user).count
end
