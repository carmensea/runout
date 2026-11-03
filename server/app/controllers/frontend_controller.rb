# Serves the built React app for every browser route, from the API's own origin, so session cookies
# stay first-party. The shell holds no user data: everything personal comes from /api after sign-in.
class FrontendController < ActionController::API
  def show
    index = Rails.configuration.x.frontend_index
    return head :not_found unless index.exist?

    response.headers["Cache-Control"] = "no-cache"
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    send_file index, type: "text/html", disposition: "inline"
  end
end
