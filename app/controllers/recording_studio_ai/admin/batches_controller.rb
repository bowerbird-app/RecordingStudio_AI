# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class BatchesController < ApplicationController
      def show
        @batch = visible_batches.includes(batch_items: %i[run response]).find(params[:id])
        @sensitive = sensitive_access?(@batch)
        @items = @batch.batch_items.sort_by(&:position)
      end
    end
  end
end
