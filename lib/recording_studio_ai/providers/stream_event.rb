# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class StreamEvent
      TYPES = %w[text_delta citation message_completed turn_completed failed cancelled].freeze

      attr_reader :type, :text_delta, :text, :citation, :usage, :error, :metadata

      def initialize(type:, text_delta: nil, text: nil, citation: nil, usage: nil, error: nil, metadata: {})
        @type = type.to_s
        @text_delta = text_delta
        @text = text
        @citation = citation
        @usage = usage
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "provider_stream_event.metadata")
        validate!
      end

      def to_h
        {
          type: type,
          text_delta: text_delta,
          text: text,
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
            "provider stream event type must be one of: #{TYPES.join(', ')}",
            code: "invalid_request"
          )
        end
        ensure_string!(:text_delta, text_delta)
        ensure_string!(:text, text)
        ensure_citation!
        ensure_usage!
        ensure_error!
      end

      def ensure_string!(name, value)
        return if value.nil? || value.is_a?(String)

        invalid!("#{name} must be a String")
      end

      def ensure_citation!
        return if citation.nil? || citation.is_a?(RecordingStudioAI::Contracts::Citation)

        invalid!("citation must be a RecordingStudioAI::Contracts::Citation")
      end

      def ensure_usage!
        return if usage.nil? || usage.is_a?(RecordingStudioAI::Contracts::Usage)

        invalid!("usage must be a RecordingStudioAI::Contracts::Usage")
      end

      def ensure_error!
        return if error.nil? || error.is_a?(RecordingStudioAI::Contracts::NormalizedError)

        invalid!("error must be a RecordingStudioAI::Contracts::NormalizedError")
      end

      def invalid!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end