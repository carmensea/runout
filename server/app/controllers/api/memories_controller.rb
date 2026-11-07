module Api
  # The music diary (docs/milestone-5-plan.md §4): a user's memories about songs. Every action
  # starts from the signed-in user's own memories; another user's id is 404, never 403, so nothing
  # confirms a memory exists. Memory text is never logged (filter_parameters) and never leaves the
  # server for any other service. No sharing exists: every memory is private.
  class MemoriesController < ApplicationController
    require_authentication

    # GET /api/memories?q=
    def index
      render json: Memories::Journal.call(Current.user, q: params[:q])
    end

    # POST /api/memories { song: "t123", body, rememberedOn, rememberedLabel }
    def create
      track = Memories::Songs.resolve(params[:song])
      return render(json: { error: "song_not_identified" }, status: :unprocessable_content) unless track

      memory = Current.user.memories.new(track: track, **attributes)
      memory.save!
      render json: Memories::Serializer.memory(memory, root: track), status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: "invalid", details: e.record.errors.to_hash }, status: :unprocessable_content
    rescue ArgumentError
      render json: { error: "invalid_date" }, status: :unprocessable_content
    end

    # PATCH /api/memories/:id { body, rememberedOn, rememberedLabel }
    def update
      memory = find_memory or return head(:not_found)
      memory.update!(attributes)
      render json: Memories::Serializer.memory(memory)
    rescue ActiveRecord::RecordInvalid => e
      render json: { error: "invalid", details: e.record.errors.to_hash }, status: :unprocessable_content
    rescue ArgumentError
      render json: { error: "invalid_date" }, status: :unprocessable_content
    end

    # DELETE /api/memories/:id
    def destroy
      memory = find_memory or return head(:not_found)
      memory.destroy!
      head :no_content
    end

    private

    def find_memory = Current.user.memories.find_by(id: params[:id])

    # Only what a person may set; a blank date or label clears it. A date that isn't one raises.
    def attributes
      attrs = {}
      attrs[:body] = params[:body].to_s if params.key?(:body)
      attrs[:remembered_on] = params[:rememberedOn].presence && Date.iso8601(params[:rememberedOn].to_s) if params.key?(:rememberedOn)
      attrs[:remembered_label] = params[:rememberedLabel].to_s.strip.presence if params.key?(:rememberedLabel)
      attrs
    end
  end
end
