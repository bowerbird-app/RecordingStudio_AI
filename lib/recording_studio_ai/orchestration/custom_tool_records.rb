# frozen_string_literal: true

require "json"

module RecordingStudioAI
  module Orchestration
    class CustomToolRecords
      UNAVAILABLE_MESSAGE = "Provider requested an unavailable custom tool."

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
          arguments: tool_call.arguments,
          metadata: {}
        )
      end

      def complete!(invocation, result, continuation, store_result: false)
        completed_at = Time.current
        serialized_result = JSON.generate(result)
        attributes = {
          status: "completed",
          continued_by_attempt: continuation,
          result_summary: JSON.generate(type: result.class.name, byte_size: serialized_result.bytesize),
          completed_at: completed_at,
          latency_ms: Support.elapsed_ms(invocation.started_at, completed_at),
          error_category: nil,
          error_code: nil,
          error_message: nil
        }
        # Generation keeps the result request-scoped. perform_tool stores it so a
        # finished request_id can be returned without running the tool again.
        attributes[:result] = result if store_result
        invocation.update!(attributes)
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
          error_message: UNAVAILABLE_MESSAGE,
          arguments: tool_call.arguments,
          metadata: { "parameter_count" => tool_call.arguments.length }
        )
        { invocation: invocation, error: unavailable_result }
      end

      def mark_unavailable!(invocation)
        fail!(invocation, "failed", "custom_tool_not_found", "custom_tool_not_found", UNAVAILABLE_MESSAGE)
        { invocation: invocation, error: unavailable_result }
      end

      def unavailable_result
        RecordingStudioAI::Providers::Result.new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: "custom_tool_not_found",
            code: "custom_tool_not_found",
            message: UNAVAILABLE_MESSAGE,
            retryable: false
          )
        )
      end
    end
  end
end
