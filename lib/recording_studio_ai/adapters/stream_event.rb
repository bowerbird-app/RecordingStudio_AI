# frozen_string_literal: true

module RecordingStudioAI
  module Adapters
    class StreamEvent
      TYPES = %w[text_delta citation].freeze

      attr_reader :type, :text_delta, :citation, :metadata

      def initialize(type:, text_delta: nil, citation: nil, metadata: {})
        @type = type.to_s
        @text_delta = text_delta
        @citation = citation
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "adapter_stream_event.metadata")
        validate!
      end

      def to_h
        {
          type: type,
          text_delta: text_delta,
          citation: citation&.to_h,
          metadata: metadata
        }
      end

      private

      def validate!
        unless TYPES.include?(type)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "adapter stream event type must be one of: #{TYPES.join(', ')}",
            code: "invalid_request"
          )
        end
        unless text_delta.nil? || text_delta.is_a?(String)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "text_delta must be a String",
            code: "invalid_request"
          )
        end
        return if citation.nil? || citation.is_a?(RecordingStudioAI::Contracts::Citation)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "citation must be a RecordingStudioAI::Contracts::Citation",
          code: "invalid_request"
        )
      end
    end
  end
end