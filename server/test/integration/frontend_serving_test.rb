require "test_helper"

class FrontendServingTest < ActionDispatch::IntegrationTest
  setup do
    @dir = Dir.mktmpdir
    @index = Pathname(@dir).join("index.html")
    @index.write("<div id=root></div>")
    @original = Rails.configuration.x.frontend_index
    Rails.configuration.x.frontend_index = @index
  end

  teardown do
    Rails.configuration.x.frontend_index = @original
    FileUtils.remove_entry(@dir)
  end

  test "browser routes get the shell, uncached and unindexed" do
    %w[/ /overview /settings /genres/rock /time-machine].each do |path|
      get path
      assert_response :success, path
      assert_equal "<div id=root></div>", response.body
      assert_includes response.media_type, "text/html"
      assert_equal "no-cache", response.headers["Cache-Control"]
      assert_equal "noindex, nofollow", response.headers["X-Robots-Tag"]
    end
  end

  test "the shell needs no session and contains no user data" do
    get "/overview"
    assert_nil response.cookies["runout_session"]
    assert_response :success
  end

  test "private data still requires a session under the same origin" do
    %w[/api/overview /api/search /api/plays /api/calendar /api/listening-sources].each do |path|
      get path
      assert_response :unauthorized, path
    end
  end

  test "unknown API paths and missing assets are 404s, never the shell" do
    %w[/api/nope /api /assets/missing-abc123.js /favicon.png].each do |path|
      get path
      assert_response :not_found, path
      assert_not_includes response.body, "id=root", path
    end
  end

  test "without a built frontend the routes are 404s" do
    @index.delete
    get "/overview"
    assert_response :not_found
  end
end
