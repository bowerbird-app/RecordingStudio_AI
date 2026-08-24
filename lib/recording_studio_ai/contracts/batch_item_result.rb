# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class BatchItemResult
      attr_reader :reference, :provider_item_id, :status, :text, :structured_data, :citations,
                  :provider_native_tools, :finish_reason, :usage, :cost, :error, :metadata

      def initialize(reference:, status:, provider_item_id: nil, text: nil, structured_data: nil, citations: [],
                     provider_native_tools: [], finish_reason: nil, usage: nil, cost: nil, error: nil, metadata: {})
        @reference = reference.to_s
        @provider_item_id = provider_item_id&.to_s
        @status = status.to_s
        @text = text
        @structured_data = Containment.ensure_serializable!(structured_data, path: "batch_item_result.structured_data")
        @citations = citations
        @provider_native_tools = Array(provider_native_tools).map(&:to_s)
        @finish_reason = finish_reason&.to_s
        @usage = usage
        @cost = cost
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "batch_item_result.metadata")
        validate!
      end

      def success? = status == "completed" && error.nil?

      def to_h
        {
          reference: reference, provider_item_id: provider_item_id, status: status, text: text,
          structured_data: structured_data, citations: citations.map(&:to_h),
          provider_native_tools: provider_native_tools, finish_reason: finish_reason,
          usage: usage&.to_h, cost: cost&.to_h, error: error&.to_h, metadata: metadata
        }
      end

      private

      def validate!
        valid = (text.nil? || text.is_a?(String)) &&
          Providers::BatchItemResult::STATUSES.include?(status) &&
                citations.all? { |citation| citation.is_a?(Citation) } &&
                (usage.nil? || usage.is_a?(Usage)) && (cost.nil? || cost.is_a?(Cost)) &&
                (error.nil? || error.is_a?(NormalizedError))
        return if valid

        raise Errors::ContractValidationError.new("invalid batch item result", code: "invalid_request")
      end
    end
  end
end