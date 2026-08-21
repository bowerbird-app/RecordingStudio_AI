# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    # Shared Result/error and stream-metadata helpers for custom tool flow.
    module CustomToolSupport
      module_function

      def failure(code, category: "custom_tool_failed", message: "Custom tool execution failed.")
        RecordingStudioAI::Providers::Result.new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: category, code: code, message: message, retryable: false
          )
        )
      end

      def invocation_metadata(invocation)
        {
          invocation_id: invocation.id,
          provider_tool_call_id: invocation.provider_tool_call_id,
          tool_key: invocation.tool_key,
          tool_version: invocation.tool_version,
          status: invocation.status
        }
      end
    end
  end
end
