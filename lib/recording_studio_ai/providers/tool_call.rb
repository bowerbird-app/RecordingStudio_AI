# frozen_string_literal: true

require "json"

module RecordingStudioAI
  module Providers
    class ToolCall
      MAX_KEY_LENGTH = 64
      MAX_PROVIDER_TOOL_CALL_ID_LENGTH = 255

      attr_reader :provider_tool_call_id, :key, :arguments

      def initialize(provider_tool_call_id:, key:, arguments:)
        @provider_tool_call_id = provider_tool_call_id.to_s
        @key = key.to_s
        @arguments = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          arguments,
          path: "provider_tool_call.arguments"
        )
        enforce_arguments_size!(@arguments)

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
        valid_key = key.length <= MAX_KEY_LENGTH && key.match?(/\A[a-z0-9_]+\z/)
        return if valid_id && valid_key && arguments.is_a?(Hash)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool call requires an id, snake_case key, and Hash arguments",
          code: "invalid_request"
        )
      end

      def enforce_arguments_size!(value)
        limit = RecordingStudioAI.configuration.maximum_custom_tool_arguments_size
        return if limit.nil? || limit <= 0

        bytes = JSON.generate(value).bytesize
        return if bytes <= limit

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "provider tool call arguments exceed maximum_custom_tool_arguments_size (#{limit} bytes)",
          code: "invalid_request"
        )
      end
    end
  end
end
