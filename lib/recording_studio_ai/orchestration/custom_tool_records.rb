# frozen_string_literal: true

require "json"

module RecordingStudioAI
  module Orchestration
    class CustomToolRecords
      def create!(run, requesting_attempt, tool_call, definition)
        run.custom_tool_invocations.create!(
          requested_by_attempt: requesting_attempt,
          provider_tool_call_id: tool_call.provider_tool_call_id,
          tool_key: definition.key,
          tool_version: definition.version,
          tool_name_snapshot: definition.name,
          status: "requested",
          read_only: definition.read_only,
          destructive: definition.destructive,
          requires_confirmation: definition.requires_confirmation,
          idempotent: definition.idempotent,
          latency_category: definition.latency,
          metadata: {}
        )
      end

      def complete!(invocation, result, continuation)
        completed_at = Time.current
        serialized_result = JSON.generate(result)
        invocation.update!(
          status: "completed",
          continued_by_attempt: continuation,
          result_summary: JSON.generate(type: result.class.name, byte_size: serialized_result.bytesize),
          completed_at: completed_at,
          latency_ms: Support.elapsed_ms(invocation.started_at, completed_at)
        )
      end

      def fail!(invocation, status, category, code, message)
        return if RecordingStudioAI::CustomToolInvocation.terminal_statuses.include?(invocation.status)

        completed_at = Time.current
        invocation.update!(
          status: status,
          completed_at: completed_at,
          latency_ms: invocation.started_at ? Support.elapsed_ms(invocation.started_at, completed_at) : nil,
          error_category: category,
          error_code: code,
          error_message: message
        )
      end

      def unknown(run, requesting_attempt, tool_call)
        invocation = run.custom_tool_invocations.create!(
          requested_by_attempt: requesting_attempt,
          provider_tool_call_id: tool_call.provider_tool_call_id,
          tool_key: tool_call.key,
          tool_version: 0,
          tool_name_snapshot: tool_call.key,
          status: "failed",
          read_only: false,
          destructive: false,
          requires_confirmation: false,
          idempotent: false,
          completed_at: Time.current,
          error_category: "custom_tool_not_found",
          error_code: "custom_tool_not_found",
          error_message: "Provider requested an unavailable custom tool.",
          metadata: { "parameter_count" => tool_call.arguments.length }
        )
        {
          invocation: invocation,
          error: RecordingStudioAI::Providers::Result.new(
            error: RecordingStudioAI::Contracts::NormalizedError.new(
              category: "custom_tool_not_found",
              code: "custom_tool_not_found",
              message: "Provider requested an unavailable custom tool.",
              retryable: false
            )
          )
        }
      end
    end
  end
end
