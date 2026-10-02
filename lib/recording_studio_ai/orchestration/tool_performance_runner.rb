# frozen_string_literal: true

require "securerandom"

module RecordingStudioAI
  module Orchestration
    # Runs one registered tool without a model call. A request_id identifies
    # the agent step: the first call executes, a pending confirmation resumes,
    # and a finished call returns the stored outcome.
    class ToolPerformanceRunner
      OPEN_INVOCATION_STATUSES = %w[requested authorized running].freeze

      def initialize(configuration:)
        @configuration = configuration
        @runs = RunPersistence.new(configuration: configuration)
        @records = CustomToolRecords.new
        @execution = CustomToolExecution.new(configuration: configuration, records: @records)
      end

      def call(request)
        RecordingStudioAI::ApplicationRecord.transaction do
          existing = find_existing(request)
          raise_missing_resume! if request[:resume] && existing.nil?
          if existing
            resume_or_replay(existing, request)
          else
            perform_new(request)
          end
        end
      end

      private

      def perform_new(request)
        request = with_deadline(request)
        reference = request.fetch(:tool)
        tool_call = tool_call_for(
          key: reference.fetch(:key),
          arguments: request.fetch(:arguments),
          call_id: provider_call_id(request)
        )
        run = @runs.create_tool!(request)
        outcome = @execution.execute(run, execution_request(request), nil, tool_call)
        finish!(run, outcome)
      end

      def resume_or_replay(run, request)
        invocation = run.custom_tool_invocations.order(:id).first
        if invocation.nil? || OPEN_INVOCATION_STATUSES.include?(invocation.status)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool run is already in progress",
            code: "invalid_request"
          )
        end
        return continue(run, request, invocation) if request[:resume] && invocation.awaiting_confirmation?

        performance_from(run, invocation)
      end

      def continue(run, request, invocation)
        request = with_deadline(request)
        tool_call = tool_call_for(
          key: invocation.tool_key,
          arguments: invocation.arguments || {},
          call_id: invocation.provider_tool_call_id
        )
        outcome = @execution.resume(
          run,
          execution_request(
            request,
            definition_key: invocation.tool_key,
            definition_version: invocation.tool_version
          ),
          invocation,
          tool_call
        )
        finish!(run, outcome)
      end

      def finish!(run, outcome)
        failure = outcome[:error]
        invocation = outcome[:invocation] || run.custom_tool_invocations.order(:id).last
        if failure.nil?
          stored = outcome.fetch(:result)
          @records.complete!(invocation, stored, nil, store_result: true)
          invocation.reload
          complete_run!(run, status: "completed")
          return build(run, "completed", invocation.result, nil)
        end

        normalized = failure.error
        if normalized.code == "custom_tool_confirmation_pending"
          run.update!(custom_tool_invocation_count: run.custom_tool_invocations.count)
          return build(run, "awaiting_confirmation", nil, normalized)
        end

        invocation.reload
        public_status = %w[failed rejected denied cancelled].include?(invocation.status) ? invocation.status : "failed"
        run_status = public_status == "cancelled" ? "cancelled" : "failed"
        complete_run!(run, status: run_status, error: normalized)
        build(run, public_status, nil, normalized)
      end

      def performance_from(run, invocation)
        if invocation.completed?
          build(run, "completed", invocation.result, nil)
        elsif invocation.awaiting_confirmation?
          build(run, "awaiting_confirmation", nil, normalized_error(invocation))
        else
          build(run, invocation.status, nil, normalized_error(invocation))
        end
      end

      def complete_run!(run, status:, error: nil)
        completed_at = Time.current
        run.update!(
          status: status,
          custom_tool_invocation_count: run.custom_tool_invocations.count,
          **Support.completion_clock(run.started_at, completed_at),
          **Support.result_error_attributes(error)
        )
      end

      def execution_request(request, definition_key: nil, definition_version: nil)
        key = definition_key || request.fetch(:tool).fetch(:key)
        version = definition_version || request.fetch(:tool).fetch(:version)
        definition = RecordingStudioAI.tools.fetch(key, version: version)
        {
          custom_tool_definitions: definition ? [definition] : [],
          attribution: request.fetch(:attribution),
          execution_deadline: request.fetch(:execution_deadline)
        }
      end

      def tool_call_for(key:, arguments:, call_id:)
        RecordingStudioAI::Providers::ToolCall.new(
          provider_tool_call_id: call_id,
          key: key,
          arguments: arguments
        )
      end

      def provider_call_id(request)
        request_id = request.fetch(:attribution).request_id.to_s
        limit = RecordingStudioAI::Providers::ToolCall::MAX_PROVIDER_TOOL_CALL_ID_LENGTH
        return request_id if !request_id.empty? && request_id.length <= limit

        "tool_#{SecureRandom.hex(16)}"
      end

      def with_deadline(request)
        request.merge(execution_deadline: Time.current + @configuration.total_execution_timeout)
      end

      def find_existing(request)
        request_id = request.fetch(:attribution).request_id
        return nil if request_id.nil? || request_id.empty?

        RecordingStudioAI::Run.where(
          operation: "tool",
          request_id: request_id,
          root_recording_id: Support.identifier(request.fetch(:attribution).root_recording)
        ).order(:id).first
      end

      def build(run, status, result, error)
        RecordingStudioAI::Contracts::ToolPerformance.new(
          status: status,
          result: result,
          error: error,
          run: run
        )
      end

      def normalized_error(invocation)
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: invocation.error_category.presence || "custom_tool_failed",
          code: invocation.error_code.presence || "custom_tool_failed",
          message: invocation.error_message.presence || "Custom tool execution failed.",
          retryable: false
        )
      end

      def raise_missing_resume!
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "no tool run to resume",
          code: "invalid_request"
        )
      end
    end
  end
end
