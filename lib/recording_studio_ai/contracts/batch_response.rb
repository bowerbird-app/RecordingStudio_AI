# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class BatchResponse < Response
      attr_reader :batch, :status, :items

      def initialize(batch: nil, status: nil, items: [], **attributes)
        @batch = batch
        @status = status&.to_s
        @items = items
        unless items.all? { |item| item.is_a?(BatchItemResult) }
          raise Errors::ContractValidationError.new("items must contain batch item results", code: "invalid_request")
        end
        super(**attributes)
      end

      def to_h = super.merge(batch: batch, status: status, items: items.map(&:to_h))
    end
  end
end