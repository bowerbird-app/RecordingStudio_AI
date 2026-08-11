# frozen_string_literal: true

module RecordingStudioAI
  module Adapters
    class BatchItemResult
      STATUSES = %w[pending processing completed failed cancelled expired].freeze

      attr_reader :reference, :provider_item_id, :status, :text, :structured_data, :citations,
                  :provider_native_tools, :finish_reason, :usage, :cost, :error, :metadata, :retention_snapshot

      def initialize(reference:, status:, provider_item_id: nil, text: nil, structured_data: nil, citations: [],
                     provider_native_tools: [], finish_reason: nil, usage: nil, cost: nil, error: nil, metadata: {},
                     retention_snapshot: nil)
        @reference = reference.to_s
        @provider_item_id = provider_item_id&.to_s
        @status = status.to_s
        @text = text
        @structured_data = Contracts::Containment.ensure_serializable!(structured_data, path: "batch_item.structured_data")
        @citations = citations
        @provider_native_tools = Array(provider_native_tools).map(&:to_s)
        @finish_reason = finish_reason&.to_s
        @usage = usage
        @cost = cost
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "batch_item.metadata")
        @retention_snapshot = Contracts::Containment.ensure_serializable!(
          retention_snapshot, path: "batch_item.retention_snapshot"
        )
        validate!
      end

      def terminal? = %w[completed failed cancelled expired].include?(status)

      def with(**overrides)
        self.class.new(
          reference: reference, provider_item_id: provider_item_id, status: status, text: text,
          structured_data: structured_data, citations: citations, provider_native_tools: provider_native_tools,
          finish_reason: finish_reason, usage: usage, cost: cost, error: error, metadata: metadata,
          retention_snapshot: retention_snapshot,
          **overrides
        )
      end

      private

      def validate!
        valid_contracts = (usage.nil? || usage.is_a?(Contracts::Usage)) &&
                          (cost.nil? || cost.is_a?(Contracts::Cost)) &&
                          (error.nil? || error.is_a?(Contracts::NormalizedError)) &&
                          citations.all? { |citation| citation.is_a?(Contracts::Citation) }
        valid_tools = provider_native_tools.all? { |tool| tool.is_a?(String) }
        return if !reference.empty? && STATUSES.include?(status) && (text.nil? || text.is_a?(String)) &&
                  valid_contracts && valid_tools

        raise Errors::ContractValidationError.new("invalid adapter batch item result", code: "invalid_request")
      end
    end
  end
end