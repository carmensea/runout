module Api
  # GET /api/tracks/:key: one song for the signed-in user (Memories::Songs): its name and artist,
  # their own listening for it, the cover, and their memories about it. A key the catalogue
  # doesn't know is 404. Needs no stored plays: a song can be remembered before it is ever played
  # here, as long as the catalogue has it.
  class TracksController < ApplicationController
    require_authentication
    require_feature :memories

    def show
      track = Memories::Songs.resolve(params[:key]) or return head(:not_found)
      memories = Memories::Songs.memories_for(Current.user, track)
      render json: Memories::Songs.detail(Current.user, track).merge(memories: memories.map { |m| Memories::Serializer.memory(m, root: track) })
    end
  end
end
