# frozen_string_literal: true

module RecordingStudioAI
  module Adapters
    class Result
      attr_reader :text, :structured_data, :citations, :provider_native_tools,
                  :custom_tool_invocations, :tool_calls, :finish_reason, :usage, :cost,
                  :provider_request_id, :error, :metadata, :retention_snapshot

      def initialize(text: nil, structured_data: nil, citations: [], provider_native_tools: [],
                     custom_tool_invocations: [], tool_calls: [], finish_reason: nil, usage: nil, cost: nil,
                     provider_request_id: nil, error: nil, metadata: {}, retention_snapshot: nil)
        unless text.nil? || text.is_a?(String)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "text must be a String",
            code: "invalid_request"
          )
        end
        @text = text
        @structured_data = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          structured_data,
          path: "adapter_result.structured_data"
        )
        @citations = citations
        @provider_native_tools = provider_native_tools
        @custom_tool_invocations = custom_tool_invocations
        unless tool_calls.all? { |tool_call| tool_call.is_a?(RecordingStudioAI::Adapters::ToolCall) }
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool_calls must contain only RecordingStudioAI::Adapters::ToolCall items",
            code: "invalid_request"
          )
        end
        @tool_calls = tool_calls
        @finish_reason = finish_reason
        @usage = usage
        @cost = cost
        @provider_request_id = provider_request_id
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "adapter_result.metadata")
        @retention_snapshot = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          retention_snapshot,
          path: "adapter_result.retention_snapshot"
        )
      end

      def success?
        error.nil?
      end

      def with(**overrides)
        self.class.new(text: text,
                       structured_data: structured_data,
                       citations: citations,
                       provider_native_tools: provider_native_tools,
                       custom_tool_invocations: custom_tool_invocations,
                       tool_calls: tool_calls,
                       finish_reason: finish_reason,
                       usage: usage,
                       cost: cost,
                       provider_request_id: provider_request_id,
                       error: error,
                       metadata: metadata,
                       retention_snapshot: retention_snapshot, **overrides)
      end
    end
  end
end
