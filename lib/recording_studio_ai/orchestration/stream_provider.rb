# frozen_string_literal: true

require "timeout"

module RecordingStudioAI
  module Orchestration
    class StreamProvider
      def initialize(configuration:, stream_session: nil)
        @configuration = configuration
        @stream_session = stream_session
      end

      def execute(request, candidate)
        messages = SizedQueue.new(1)
        worker = Thread.new do
          result = provider_for!(candidate).stream(request: request, candidate: candidate) do |event|
            messages << [:event, event]
          end
          messages << [:result, result]
        rescue StandardError => e
          messages << [:error, e]
        end

        consume_messages(messages, request)
      ensure
        worker&.kill
        worker&.join(0.1)
      end

      def provider_for!(candidate)
        @configuration.providers.fetch(candidate.provider) do
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "No provider is configured for #{candidate.provider}",
            code: "configuration"
          )
        end
      end

      private

      def consume_messages(messages, request)
        loop do
          type, payload = Timeout.timeout(
            stream_idle_timeout(request),
            RecordingStudioAI::Orchestrator::StreamIdleTimeout
          ) { messages.pop }
          @stream_session&.emit_provider_event(payload) if type == :event
          return payload if type == :result
          raise payload if type == :error
        end
      end

      def stream_idle_timeout(request)
        [Support.remaining_execution_time(request), @configuration.stream_idle_timeout].min
      end
    end
  end
end
