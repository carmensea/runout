require "test_helper"

class HistoryImport::RequestBudgetTest < ActiveSupport::TestCase
  test "the limit follows the window size and is capped" do
    budget = HistoryImport::RequestBudget.new(stub_client)
    assert_equal 10, budget.limit, "before the size is known"
    budget.size_for(3)
    assert_equal 32, budget.limit, "4 snapshots x (3 + 1) pages x 2"
    budget.size_for(HistoryImport::WindowValidator::MAX_PAGES)
    assert_equal 168, budget.limit, "the largest window the validator accepts (20 pages) stays under the cap"
    budget.size_for(40)
    assert_equal HistoryImport::RequestBudget::MAX, budget.limit, "the cap is a backstop"
  end

  test "an exhausted budget stops the fetcher before it sends another request" do
    fake = FakeRecentTracks.history(count: 450, same_second_every: nil).install(self)
    client = stub_client(**Lastfm::Client::BACKGROUND_OPTIONS)
    budget = HistoryImport::RequestBudget.new(client)
    budget.define_singleton_method(:size_for) { |_pages| @limit = 2 } # pretend the allowance is tiny
    fetcher = HistoryImport::SnapshotFetcher.new(client: client, username: "listener", budget: budget)
    assert_raises(HistoryImport::SnapshotFetcher::BudgetExceeded) { fetcher.fetch(Time.utc(2020, 5, 1)...Time.utc(2020, 7, 1)) }
    assert_equal 2, fake.requests
  end

  test "budgets count real HTTP attempts, retries included" do
    stub_request(:get, Lastfm::Client::API_URL.to_s).with(query: hash_including({})).to_return({ status: 502, body: "" }, { status: 200, body: { user: { name: "x" } }.to_json })
    client = stub_client(**Lastfm::Client::BACKGROUND_OPTIONS)
    budget = HistoryImport::RequestBudget.new(client)
    client.user_info(session_key: "sk")
    assert_equal 2, budget.used
  end
end
