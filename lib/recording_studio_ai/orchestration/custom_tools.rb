# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class CustomTools
      def initialize(configuration:, persistence:, attempt_runner:, stream_session: nil)
        @configuration = configuration
        @persistence = persistence
        @attempt_runner = attempt_runner
        @stream_session = stream_session
        @records = CustomToolRecords.new
        @execution = CustomToolExecution.new(
          configuration: configuration, records: @records, stream_session: stream_session
        )
      end

      def execute_rounds(run, request, planned, executions, operation:)
        rounds = 0

        while executions.last.result.success? && executions.last.result.tool_calls.any?
          limit_failure = round_limit_failure(executions, rounds)
          if limit_failure
            executions[-1] = with_failure(executions.last, limit_failure)
            break
          end

          rounds += 1
          outcomes = run_tool_calls(run, request, executions.last)
          failed_outcome = outcomes.find { |outcome| outcome.fetch(:error) }
          if failed_outcome
            finalize_partial_successes(outcomes)
            executions[-1] = with_failure(executions.last, failed_outcome.fetch(:error))
            break
          end

          continuation, history = continue_after_tools(run, request, planned, executions, outcomes)
          result = @attempt_runner.execute(
            request.merge(history),
            planned.candidate,
            operation: operation,
            parameter_overrides: planned.parameter_overrides
          )
          result = enforce_round_limit(result, rounds)
          @persistence.complete_attempt!(continuation, result)
          executions << ExecutedAttempt.new(record: continuation, result: result)
          request = request.merge(history)
        end

        executions
      end

      private

      def round_limit_failure(executions, rounds)
        return failure("custom_tool_round_limit") if rounds >= @configuration.maximum_custom_tool_rounds
        return failure("custom_tool_attempt_limit") if executions.length >= @configuration.maximum_attempts

        nil
      end

      def run_tool_calls(run, request, execution)
        execution.result.tool_calls.map do |tool_call|
          @execution.execute(run, request, execution.record, tool_call)
        end
      end

      def finalize_partial_successes(outcomes)
        outcomes.reject { |outcome| outcome.fetch(:error) }.each do |outcome|
          @records.complete!(outcome.fetch(:invocation), outcome.fetch(:result), nil)
          emit_completed(outcome.fetch(:invocation))
        end
      end

      def continue_after_tools(run, request, planned, executions, outcomes)
        continuation = nil
        RecordingStudioAI::ApplicationRecord.transaction do
          continuation = @persistence.create_attempt!(run, request, planned, executions.length + 1, "continuation")
          outcomes.each do |outcome|
            @records.complete!(outcome.fetch(:invocation), outcome.fetch(:result), continuation)
          end
        end
        outcomes.each { |outcome| emit_completed(outcome.fetch(:invocation)) }

        history_entry = {
          calls: executions.last.result.tool_calls.map(&:to_h),
          results: outcomes.map { |outcome| outcome.fetch(:provider_result) }
        }
        history = Array(request[:custom_tool_history]) + [history_entry]
        [
          continuation,
          {
            custom_tool_calls: history_entry.fetch(:calls),
            custom_tool_results: history_entry.fetch(:results),
            custom_tool_history: history
          }
        ]
      end

      def enforce_round_limit(result, rounds)
        return result unless result.success? && result.tool_calls.any?
        return result if rounds < @configuration.maximum_custom_tool_rounds

        result.with(error: failure("custom_tool_round_limit").error, tool_calls: [])
      end

      def failure(code)
        RecordingStudioAI::Providers::Result.new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: "custom_tool_failed", code: code, message: "Custom tool execution failed.", retryable: false
          )
        )
      end

      def with_failure(execution, failure_result)
        execution.with(result: execution.result.with(error: failure_result.error, tool_calls: []))
      end

      def emit_completed(invocation)
        @stream_session&.emit("custom_tool_completed", metadata: {
                                invocation_id: invocation.id,
                                provider_tool_call_id: invocation.provider_tool_call_id,
                                tool_key: invocation.tool_key,
                                tool_version: invocation.tool_version,
                                status: invocation.status
                              })
      end
    end
  end
end
