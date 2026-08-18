# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class PlanExecutor
      def initialize(configuration:, persistence:, attempt_runner:, custom_tools:, stream_session: nil)
        @configuration = configuration
        @persistence = persistence
        @attempt_runner = attempt_runner
        @custom_tools = custom_tools
        @stream_session = stream_session
      end

      def execute(run, request, plan, operation:)
        executions = []
        provider_fallbacks = 0

        plan.each_with_index do |planned, candidate_index|
          break if attempts_exhausted?(executions) || deadline_reached?(request)

          if candidate_index.positive?
            previous = plan[candidate_index - 1]
            if same_profile_provider_fallback?(previous, planned)
              provider_fallbacks += 1
              next if provider_fallbacks > @configuration.maximum_provider_fallbacks
            end
          end

          result = execute_candidate(run, request, planned, executions, operation: operation)
          return result if result
        end

        executions
      end

      private

      def execute_candidate(run, request, planned, executions, operation:)
        (@configuration.maximum_retries_per_candidate + 1).times do |retry_index|
          break if attempts_exhausted?(executions) || deadline_reached?(request)

          attempt = @persistence.create_attempt!(
            run, request, planned, executions.length + 1, attempt_kind(executions, retry_index)
          )
          @stream_session&.active_attempt = attempt if operation == :stream
          result = @attempt_runner.execute(request, planned.candidate, operation: operation)
          @persistence.complete_attempt!(attempt, result)
          executions << ExecutedAttempt.new(record: attempt, result: result)

          if result.success? && result.tool_calls.any?
            return @custom_tools.execute_rounds(run, request, planned, executions, operation: operation)
          end
          return executions if stop_retries?(result)
          break if retry_index >= @configuration.maximum_retries_per_candidate
          break unless wait_before_retry(request, retry_index)
        end

        nil
      end

      def stop_retries?(result)
        result.success? || !result.error&.retryable? || @stream_session&.visible_output
      end

      def wait_before_retry(request, retry_index)
        remaining = request.fetch(:execution_deadline) - Time.current
        return false if remaining <= 0

        delay = retry_delay(retry_index)
        return false if delay >= remaining

        @configuration.retry_sleeper.call(delay) if delay.positive?
        true
      rescue ArgumentError, TypeError
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "retry backoff configuration is invalid", code: "configuration"
        )
      end

      def retry_delay(retry_index)
        base = Float(@configuration.retry_backoff_base)
        maximum = Float(@configuration.retry_backoff_max)
        jitter = Float(@configuration.retry_jitter)
        delay = [base * (2**retry_index), maximum].min
        delay *= 1 + (jitter * ((Float(@configuration.retry_random.call) * 2) - 1))
        delay.clamp(0, maximum)
      end

      def deadline_reached?(request)
        Time.current >= request.fetch(:execution_deadline)
      end

      def same_profile_provider_fallback?(previous, current)
        previous.profile == current.profile && previous.candidate.provider != current.candidate.provider
      end

      def attempts_exhausted?(executions)
        executions.length >= @configuration.maximum_attempts
      end

      def attempt_kind(executions, retry_index)
        return "primary" if executions.empty?
        return "retry" if retry_index.positive?

        "fallback"
      end
    end
  end
end
