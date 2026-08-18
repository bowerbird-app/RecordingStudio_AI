# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class ResponseBuilder
      def initialize(persistence:)
        @persistence = persistence
      end

      def build(request, run, executions, final_execution, operation:)
        final_result = final_execution.result
        final_attempt = final_execution.record
        RecordingStudioAI::Contracts::GenerationResponse.new(
          operation: operation.to_s,
          purpose: request[:purpose],
          profile: request[:profile],
          provider: final_attempt.provider,
          model: final_attempt.model,
          run: run,
          usage: @persistence.aggregate_usage(executions),
          cost: @persistence.aggregate_cost(executions),
          attempts: executions.map { |execution| attempt_summary(execution) },
          error: final_result.error,
          metadata: request[:metadata],
          text: final_result.text,
          structured_data: final_result.structured_data,
          citations: final_result.citations,
          provider_native_tools: final_result.provider_native_tools,
          custom_tool_invocations: custom_tool_invocation_summaries(run),
          finish_reason: final_result.finish_reason
        )
      end

      def resolution_failure(request, error, operation:)
        RecordingStudioAI::Contracts::GenerationResponse.new(
          operation: operation.to_s,
          purpose: request[:purpose],
          profile: request[:profile],
          attempts: [],
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: error.category,
            code: error.code,
            message: error.message,
            retryable: false,
            provider: request[:provider]&.to_s
          ),
          metadata: request[:metadata]
        )
      end

      private

      def attempt_summary(execution)
        attempt = execution.record
        result = execution.result
        RecordingStudioAI::Contracts::AttemptSummary.new(
          sequence: attempt.sequence,
          kind: attempt.kind,
          provider: attempt.provider,
          model: attempt.model,
          status: attempt.status,
          usage: result.usage,
          cost: result.cost,
          latency: attempt.latency_ms,
          finish_reason: attempt.finish_reason,
          error: attempt.completed? ? nil : result.error
        )
      end

      def custom_tool_invocation_summaries(run)
        return [] unless defined?(RecordingStudioAI::CustomToolInvocation)

        run.custom_tool_invocations.order(:id).map do |invocation|
          {
            id: invocation.id,
            provider_tool_call_id: invocation.provider_tool_call_id,
            tool_key: invocation.tool_key,
            tool_version: invocation.tool_version,
            status: invocation.status,
            confirmation_status: invocation.confirmation_status,
            error_category: invocation.error_category,
            error_code: invocation.error_code
          }
        end
      end
    end
  end
end
