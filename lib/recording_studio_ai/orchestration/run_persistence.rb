# frozen_string_literal: true

require "json"

module RecordingStudioAI
  module Orchestration
    class RunPersistence
      def initialize(configuration:)
        @configuration = configuration
      end

      def create!(request, candidate, operation:)
        attribution = request[:attribution]
        prompt = request[:prompt_definition]
        RecordingStudioAI::Run.create!(
          core_attributes(request, candidate, operation, prompt).merge(
            attribution_attributes(attribution),
            input_attributes(request, operation),
            metadata: request[:metadata]
          )
        )
      end

      # A tool run has no provider, model, or profile. Arguments stay on the
      # invocation; metadata is the caller's sanitized hash only.
      def create_tool!(request)
        attribution = request[:attribution]
        RecordingStudioAI::Run.create!(
          {
            operation: "tool",
            purpose: request[:purpose],
            status: "running",
            started_at: Time.current,
            metadata: request[:metadata]
          }.merge(attribution_attributes(attribution), tool_input_attributes(request))
        )
      end

      def complete!(run, executions, final_execution)
        completed_at = Time.current
        final_result = final_execution.result
        final_attempt = final_execution.record
        usage = Aggregation.usage(executions)
        run.update!(Aggregation.token_metrics(usage).merge(
                      Support.result_completion_attributes(
                        final_result, started_at: run.started_at, completed_at: completed_at
                      ),
                      resolved_provider: final_attempt.provider,
                      resolved_model: final_attempt.model,
                      attempt_count: executions.length,
                      retry_count: executions.count { |execution| execution.record.kind == "retry" },
                      fallback_count: executions.count { |execution| execution.record.kind == "fallback" },
                      custom_tool_invocation_count: custom_tool_invocation_count(run),
                      **output_attributes(executions, final_result, operation: run.operation)
                    ))
      end

      # Persists the failed terminal state and returns its normalized error. The
      # public response stays the ResponseBuilder's job.
      def complete_deadline_failure(run)
        error = deadline_error(run.resolved_provider)
        completed_at = Time.current
        run.update!(
          status: "failed",
          attempt_count: 0,
          **Support.completion_clock(run.started_at, completed_at),
          **Support.result_error_attributes(error)
        )
        error
      end

      private

      def tool_input_attributes(request)
        payload = request[:arguments].nil? ? "" : JSON.generate(request[:arguments])
        RecordingStudioAI::Attachments.metadata([]).merge(
          input_character_count: payload.length,
          web_search_requested: false
        )
      end

      def input_attributes(request, operation)
        return decision_input_attributes(request) if operation == :decision

        RecordingStudioAI::Attachments.metadata(request[:attachments]).merge(
          input_character_count: Support.request_input(request).length,
          web_search_requested: Array(request[:provider_native_tools]).include?(:web_search)
        )
      end

      # Decision state, question instructions, and criteria never reach a column.
      # Only the caller-supplied character count crosses this boundary.
      def decision_input_attributes(request)
        RecordingStudioAI::Attachments.metadata([]).merge(
          input_character_count: request.fetch(:input_character_count),
          web_search_requested: false
        )
      end

      def output_attributes(executions, final_result, operation:)
        counted = { output_character_count: Support.result_output_character_count(final_result) }
        return counted.merge(web_search_used: false, citation_count: 0) if operation == "decision"

        counted.merge(
          web_search_used: executions.any? do |execution|
            execution.result.provider_native_tools.include?("web_search")
          end,
          citation_count: executions.sum { |execution| execution.result.citations.length }
        )
      end

      def core_attributes(request, candidate, operation, prompt)
        {
          operation: operation.to_s,
          purpose: request[:purpose],
          prompt_key: prompt&.key,
          prompt_version: prompt&.version,
          prompt_name_snapshot: prompt&.name,
          status: "running",
          profile_key: request[:profile],
          requested_provider: request[:provider],
          resolved_provider: candidate.provider,
          resolved_model: candidate.model,
          started_at: Time.current
        }
      end

      def attribution_attributes(attribution)
        {
          root_recording_id: Support.identifier(attribution.root_recording),
          context_recording_id: Support.identifier(attribution.context_recording),
          initiator_type: attribution.initiator.class.name,
          initiator_id: Support.identifier(attribution.initiator),
          initiator_kind: attribution.initiator_kind,
          executor_type: attribution.executor&.class&.name,
          executor_id: Support.identifier(attribution.executor),
          impersonator_type: attribution.impersonator&.class&.name,
          impersonator_id: Support.identifier(attribution.impersonator),
          execution_source: attribution.execution_source,
          request_id: attribution.request_id,
          job_id: attribution.job_id
        }
      end

      def custom_tool_invocation_count(run)
        return 0 unless defined?(RecordingStudioAI::CustomToolInvocation)

        run.custom_tool_invocations.count
      end

      def deadline_error(provider)
        RecordingStudioAI::Contracts::NormalizedError.new(
          category: "timeout",
          code: "execution_deadline_exceeded",
          message: "AI execution exceeded its configured deadline.",
          retryable: false,
          provider: provider
        )
      end
    end
  end
end
