module Api
  # Listening-history review (docs/milestone-2-plan.md §15.2), through the same service and audit
  # trail as the command line (HistoryImport::Review), recorded with source "web".
  #
  # Every decision names the item's version as the reviewer saw it; if the item changed meanwhile,
  # nothing is decided and the current item comes back (409). Repeating a decision that was already
  # made changes nothing ("already"). Removing a play and applying a correction need `confirm`.
  class ReviewsController < ApplicationController
    include HistoryControls

    before_action :require_storage!, only: :decide

    DECISIONS = {
      "removal" => { "approve" => :approve_removal!, "dismiss" => :dismiss_removal! },
      "reappeared" => { "restore" => :restore_reappeared!, "keep" => :keep_removed! },
      "dispute" => { "resolve" => :resolve_dispute!, "dismiss" => :dismiss_dispute! }
    }.freeze
    NEEDS_CONFIRMATION = %w[approve keep resolve].freeze

    def index
      render json: HistoryImport::ReviewQueue.for(Current.user, offset: params[:offset].to_i.clamp(0, 1_000_000))
    end

    def decide
      method = DECISIONS.dig(params[:kind], params[:decision]) or return head(:not_found)
      item = find_item or return head(:not_found)
      return render json: { error: "version_required" }, status: :unprocessable_content if params[:version].blank?
      if NEEDS_CONFIRMATION.include?(params[:decision]) && !confirmed?
        return render json: { error: "confirmation_required" }, status: :unprocessable_content
      end

      options = { by: Current.user, note: params[:note].presence&.to_s&.truncate(500), source: "web", expected_version: params[:version].to_s }
      options[:pairs] = pairs if params[:decision] == "resolve"
      result = HistoryImport::Review.public_send(method, item, **options)
      render json: { result: result.to_s, item: current_item(item) }
    rescue HistoryImport::Review::Changed
      render json: { error: "changed", item: current_item(item) }, status: :conflict
    rescue HistoryImport::Review::Invalid, ArgumentError, TypeError => e
      render json: { error: "invalid", message: e.message }, status: :unprocessable_content
    end

    private

    def find_item
      scope = params[:kind] == "dispute" ? ReconciliationDispute : ScrobbleRemoval
      scope.find_by(user_id: Current.user.id, id: params[:id])
    end

    # [[stored play id, fetched play index], ...]
    def pairs
      Array(params[:pairs]).map { |pair| Array(pair).then { |id, index| [ Integer(id.to_s), Integer(index.to_s) ] } }
    end

    # The item as the queue shows it now, or nil once it no longer needs review.
    def current_item(item)
      item.reload
      return nil unless (item.is_a?(ScrobbleRemoval) && %w[pending_review reappeared].include?(item.state)) ||
                        (item.is_a?(ReconciliationDispute) && item.state == "open")

      HistoryImport::ReviewQueue.for(Current.user, limit: 1_000)[:items].find { |i| i[:subjectType] == item.class.name && i[:id] == item.id }
    end
  end
end
