# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    class ToolCall
      MAX_KEY_LENGTH = 64
      MAX_PROVIDER_TOOL_CALL_ID_LENGTH = 255

      attr_reader :provider_tool_call_id, :key, :arguments

      def self.valid_key?(key)
        value = key.to_s
        value.length <= MAX_KEY_LENGTH && value.match?(/\A[a-z0-9_]+\z/)
      end

      def initialize(provider_tool_call_id:, key:, arguments:)
        @provider_tool_call_id = provider_tool_call_id.to_s
        @key = key.to_s
        @arguments = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          arguments,
          path: "provider_tool_call.arguments"
        )

        validate!
      end

      def to_h
        {
          provider_tool_call_id: provider_tool_call_id,
          key: key,
          arguments: arguments
        }
      end

      private

      def validate!
        valid_id = !provider_tool_call_id.empty? && provider_tool_call_id.length <= MAX_PROVIDER_TOOL_CALL_ID_LENGTH
        return if valid_id && self.class.valid_key?(key) && arguments.is_a?(Hash)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool call requires an id, snake_case key, and Hash arguments",
          code: "invalid_request"
        )
      end
    end
  end
end