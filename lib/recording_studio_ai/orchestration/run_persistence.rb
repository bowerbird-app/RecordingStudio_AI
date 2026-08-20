# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class RunPersistence
      def initialize(configuration:)
        @configuration = configuration
      end

      def create!(request, candidate, operation:)
        attribution = request[:attribution]
        input = Support.request_input(request)
        attachment_metadata = RecordingStudioAI::Attachments.metadata(request[:attachments])
        prompt = request[:prompt_definition]
        RecordingStudioAI::Run.create!(
          core_attributes(request, candidate, operation, prompt).merge(
            attribution_attributes(attribution),
            attachment_metadata,
            input_character_count: input.length,
            web_search_requested: request[:provider_native_tools].include?(:web_search),
            metadata: request[:metadata]
          )
        )
      end

      def complete!(run, executions, final_execution)
        completed_at = Time.current
        final_result = final_execution.result
        final_attempt = final_execution.record
        usage = Aggregation.usage(executions)
        run.update!(Aggregation.token_metrics(usage).merge(
                      status: final_result.success? ? "completed" : "failed",
                      resolved_provider: final_attempt.provider,
                      resolved_model: final_attempt.model,
                      attempt_count: executions.length,
                      retry_count: executions.count { |execution| execution.record.kind == "retry" },
                      fallback_count: executions.count { |execution| execution.record.kind == "fallback" },
                      custom_tool_invocation_count: custom_tool_invocation_count(run),
                      completed_at: completed_at,
                      latency_ms: Support.elapsed_ms(run.started_at, completed_at),
                      output_character_count: final_result.text&.length,
                      web_search_used: executions.any? do |execution|
                        execution.result.provider_native_tools.include?("web_search")
                      end,
                      citation_count: executions.sum { |execution| execution.result.citations.length },
                      error_category: final_result.error&.category,
                      error_code: final_result.error&.code,
                      error_message: final_result.error&.message
                    ))
      end

      def complete_deadline_failure(request, run, operation:)
        error = deadline_error(run.resolved_provider)
        completed_at = Time.current
        run.update!(
          status: "failed",
          attempt_count: 0,
          completed_at: completed_at,
          latency_ms: Support.elapsed_ms(run.started_at, completed_at),
          error_category: error.category,
          error_code: error.code,
          error_message: error.message
        )
        RecordingStudioAI::Contracts::GenerationResponse.new(
          operation: operation.to_s,
          purpose: request[:purpose],
          profile: request[:profile],
          provider: run.resolved_provider,
          model: run.resolved_model,
          run: run,
          attempts: [],
          error: error,
          metadata: request[:metadata]
        )
      end

      private

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
