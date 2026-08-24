# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class AttemptPersistence
      def initialize(configuration:)
        @configuration = configuration
      end

      def create!(run, request, planned, sequence, kind)
        attachment_metadata = RecordingStudioAI::Attachments.metadata(request[:attachments])
        run.attempts.create!(
          sequence: sequence,
          kind: kind,
          status: "running",
          profile_key: planned.profile,
          provider: planned.candidate.provider,
          model: planned.candidate.model,
          streaming: run.operation == "stream",
          **attachment_metadata,
          provider_file_count: %i[openai gemini].include?(planned.candidate.provider) ? 0 : nil,
          web_search_requested: request[:provider_native_tools].include?(:web_search),
          started_at: Time.current
        )
      end

      def complete!(attempt, result)
        completed_at = Time.current
        attempt.update!(Aggregation.token_metrics(result.usage).merge(
                          Support.result_completion_attributes(
                            result, started_at: attempt.started_at, completed_at: completed_at
                          ),
                          provider_request_id: result.provider_request_id,
                          finish_reason: result.finish_reason,
                          retryable: result.error&.retryable?,
                          web_search_used: result.provider_native_tools.include?("web_search"),
                          citation_count: result.citations.length,
                          metadata: result.metadata
                        ))
        RecordingStudioAI::Retention.retain_attempt!(attempt, result, configuration: @configuration)
      end
    end
  end
end
