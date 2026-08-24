# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class StreamingEvent
      TYPES = %w[
        text_delta
        citation
        custom_tool_requested
        custom_tool_started
        custom_tool_completed
        usage
        completed
        error
      ].freeze

      attr_reader :type, :text_delta, :citation, :usage, :error, :metadata

      def initialize(type:, text_delta: nil, citation: nil, usage: nil, error: nil, metadata: {})
        @type = type.to_s
        @text_delta = text_delta
        @citation = citation
        @usage = usage
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "stream_event.metadata")

        validate!
      end

      def to_h
        {
          type: type,
          text_delta: text_delta,
          citation: citation&.to_h,
          usage: usage&.to_h,
          error: error&.to_h,
          metadata: metadata
        }
      end

      private

      def validate!
        unless TYPES.include?(type)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "streaming event type must be one of: #{TYPES.join(', ')}",
            code: "invalid_request"
          )
        end

        unless text_delta.nil? || text_delta.is_a?(String)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "text_delta must be a String",
            code: "invalid_request"
          )
        end

        unless citation.nil? || citation.is_a?(RecordingStudioAI::Contracts::Citation)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "citation must be a RecordingStudioAI::Contracts::Citation",
            code: "invalid_request"
          )
        end

        unless usage.nil? || usage.is_a?(RecordingStudioAI::Contracts::Usage)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "usage must be a RecordingStudioAI::Contracts::Usage",
            code: "invalid_request"
          )
        end

        return if error.nil? || error.is_a?(RecordingStudioAI::Contracts::NormalizedError)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "error must be a RecordingStudioAI::Contracts::NormalizedError",
          code: "invalid_request"
        )
      end
    end
  end
end
