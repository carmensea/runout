# Shared by the import, sync and review endpoints (docs/milestone-2-plan.md §15): every action
# needs a signed-in user and acts on that user's data only, and nothing that changes history runs
# while history storage is off.
module HistoryControls
  extend ActiveSupport::Concern

  included do
    require_authentication
  end

  private

  def require_storage!
    render json: { error: "storage_disabled" }, status: :conflict unless HistoryImport.enabled?
  end

  def confirmed? = ActiveModel::Type::Boolean.new.cast(params[:confirm]) == true
end
