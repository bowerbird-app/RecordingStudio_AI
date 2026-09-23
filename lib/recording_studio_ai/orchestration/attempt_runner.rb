# frozen_string_literal: true

require "timeout"

module RecordingStudioAI
  module Orchestration
    class AttemptRunner
      def initialize(configuration:, stream_session: nil)
        @configuration = configuration
        @stream_session = stream_session
        @stream_provider = StreamProvider.new(configuration: configuration, stream_session: stream_session)
      end

      def execute(request, candidate, operation:, parameter_overrides: {})
        unless operation == :decision
          request = apply_resolved_generation_parameters!(
            request, candidate, parameter_overrides: parameter_overrides
          )
        end
        buffer_stream_events = operation == :stream && request[:schema]
        @stream_session&.start_buffering! if buffer_stream_events
        result = run_provider(request, candidate, operation: operation)
        ensure_result_for_operation!(result, operation: operation)
        result = apply_cost_and_schema(result, request, candidate, operation: operation)
        @stream_session&.flush_buffer if buffer_stream_events && result.success?
        result
      rescue RecordingStudioAI::Orchestrator::StreamConsumerError
        raise
      rescue RecordingStudioAI::Orchestrator::StreamIdleTimeout
        timeout_result(candidate, operation: operation, code: "stream_idle_timeout",
                                  message: "AI stream exceeded its configured idle timeout.", retryable: false)
      rescue RecordingStudioAI::Orchestrator::ProviderRequestTimeout
        timeout_result(candidate, operation: operation, code: "provider_timeout",
                                  message: "AI provider request exceeded its configured timeout.", retryable: true)
      rescue Timeout::Error
        timeout_result(candidate, operation: operation, code: "execution_deadline_exceeded",
                                  message: "AI execution exceeded its configured deadline.", retryable: false)
      # NotImplementedError is a ScriptError, so the rescue below cannot see the
      # unimplemented provider-contract defaults.
      rescue RecordingStudioAI::Providers::UnsupportedOperationError, NotImplementedError
        unsupported_operation_result(candidate, operation: operation)
      rescue StandardError
        provider_failure(candidate, operation: operation)
      ensure
        @stream_session&.clear_buffer! if buffer_stream_events
      end

      def provider_for!(candidate)
        @stream_provider.provider_for!(candidate)
      end

      private

      def run_provider(request, candidate, operation:)
        timeout, timeout_error = provider_timeout(request)
        Timeout.timeout(timeout, timeout_error) do
          case operation
          when :stream
            @stream_provider.execute(request, candidate)
          when :generation
            provider_for!(candidate).generate(request: request, candidate: candidate)
          when :decision
            provider_for!(candidate).decide(request: request, candidate: candidate)
          else
            raise RecordingStudioAI::Providers::UnsupportedOperationError.new(
              operation: operation, provider: candidate.provider
            )
          end
        end
      end

      def apply_cost_and_schema(result, request, candidate, operation:)
        result = RecordingStudioAI::CostCalculator.apply(
          result, provider: candidate.provider, model: candidate.model, configuration: @configuration
        )
        return result if operation == :decision
        return result unless result.tool_calls.empty?

        RecordingStudioAI::StructuredOutput.apply(
          result, schema: request[:schema], provider: candidate.provider
        )
      end

      def apply_resolved_generation_parameters!(request, candidate, parameter_overrides: {})
        definition = RecordingStudioAI.models.fetch(candidate.provider, candidate.model)
        known = RecordingStudioAI::Models::Definition::KNOWN_PARAMETERS
        caller_provided = known.index_with { |name| request[name] }.compact
        overlays = RecordingStudioAI::FallbackEntries.parameter_overrides_from(
          parameter_overrides.to_h.transform_keys(&:to_sym)
        )
        overlays = overlays.reject { |name, _value| caller_provided.key?(name) }
        return request if caller_provided.empty? && overlays.empty?
        return request.merge(caller_provided.merge(overlays)) unless definition

        adapted_caller = RecordingStudioAI::Models::ParameterValidation.adapt_for_model(
          definition, caller_provided
        )
        adapted_overlay = if overlays.empty?
                            known.index_with { nil }
                          else
                            RecordingStudioAI::Models::ParameterValidation.adapt_for_model(definition, overlays)
                          end

        request.merge(
          known.to_h do |name|
            value = adapted_caller[name]
            value = adapted_overlay[name] if value.nil?
            [name, value]
          end
        )
      end

      def provider_timeout(request)
        remaining = Support.remaining_execution_time(request)
        request_timeout = @configuration.request_timeout
        return [request_timeout, RecordingStudioAI::Orchestrator::ProviderRequestTimeout] if request_timeout < remaining

        [remaining, Timeout::Error]
      end

      def ensure_result_for_operation!(result, operation:)
        expected = result_class(operation)
        return if result.is_a?(expected)

        raise TypeError, "Provider must return #{expected}"
      end

      def result_class(operation)
        return RecordingStudioAI::Providers::DecisionResult if operation == :decision

        RecordingStudioAI::Providers::Result
      end

      def timeout_result(candidate, operation:, code:, message:, retryable:)
        result_class(operation).new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: "timeout",
            code: code,
            message: message,
            retryable: retryable,
            provider: candidate.provider.to_s
          )
        )
      end

      def unsupported_operation_result(candidate, operation:)
        result_class(operation).new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: "configuration",
            code: "unsupported_operation",
            message: "Provider does not implement the requested operation.",
            retryable: false,
            provider: candidate.provider.to_s
          )
        )
      end

      def provider_failure(candidate, operation:)
        result_class(operation).new(
          error: RecordingStudioAI::Contracts::NormalizedError.new(
            category: "provider_error",
            code: "provider_execution_error",
            message: "Provider execution failed.",
            retryable: false,
            provider: candidate.provider.to_s
          )
        )
      end
    end
  end
end
