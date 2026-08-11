# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class BatchesController < ApplicationController
      def index
        @batches = visible_batches.order(created_at: :desc).limit(100)
        @sensitive_roots = @admin_access.root_ids.index_with do |root_id|
          @admin_access.allowed?(:view_sensitive_execution, root_id: root_id, context: { collection: "batches" })
        end
      end

      def show
        @batch = visible_batches.includes(batch_items: %i[run response]).find(params[:id])
        @sensitive = sensitive_access?(@batch)
        @items = @batch.batch_items.sort_by(&:position)
      end
    end
  end
end
