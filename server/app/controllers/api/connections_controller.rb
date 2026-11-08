module Api
  # GET /api/connection: matches the frontend's ConnectionState (src/data/types.ts).
  # Signed-out visitors get { status: "none" } rather than 401: with Last.fm-only sign-in,
  # "not signed in" and "no Last.fm account connected" are the same state.
  class ConnectionsController < ApplicationController
    def show
      render json: ConnectionState.for(Current.user, session: Current.session)
    end
  end
end
