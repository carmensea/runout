module Api
  # /api/overview and /api/search arrive with Milestone 3 (docs/milestone-2-plan.md §8.3). Until
  # then they answer 501, which the frontend shows as "charts arrive in the next version".
  class UnavailableController < ApplicationController
    def show
      render json: { error: "not_available" }, status: :not_implemented
    end
  end
end
