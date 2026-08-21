# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class StreamSession
      attr_accessor :active_run, :active_attempt, :active_cancellation_state
      attr_reader :visible_output

      def initialize(event_handler:)
        @event_handler = event_handler
        @visible_output = false
        @stream_event_buffer = nil
      end

      def start_buffering!
        @stream_event_buffer = []
      end

      def buffering?
        !@stream_event_buffer.nil?
      end

      def clear_buffer!
        @stream_event_buffer = nil
      end

      def emit_provider_event(event)
        unless event.is_a?(RecordingStudioAI::Providers::StreamEvent)
          raise TypeError, "Provider must yield RecordingStudioAI::Providers::StreamEvent"
        end

        return @stream_event_buffer << event if @stream_event_buffer

        deliver_provider_event(event)
      end

      def flush_buffer
        events = @stream_event_buffer
        @stream_event_buffer = nil
        events.each { |event| deliver_provider_event(event) }
      end

      def emit(type, **attributes)
        return unless @event_handler

        @event_handler.call(RecordingStudioAI::Contracts::StreamingEvent.new(type: type, **attributes))
        @visible_output = true
      rescue RecordingStudioAI::Orchestrator::StreamConsumerError
        raise
      rescue StandardError => e
        raise RecordingStudioAI::Orchestrator::StreamConsumerError, e
      end

      def emit_final(response)
        unless response.success?
          emit("error", error: response.error, metadata: response.metadata)
          return
        end

        emit("usage", usage: response.usage) if response.usage
        emit("completed", metadata: response.metadata)
      end

      def cancel_records!
        active_cancellation_state&.cancel!
        completed_at = Time.current
        cancel_running_attempts!(completed_at)
        cancel_active_run!(completed_at)
        cancel_custom_tool_invocations!
      end

      private

      def deliver_provider_event(event)
        emit(
          event.type,
          text_delta: event.text_delta,
          citation: event.citation,
          metadata: event.metadata
        )
      end

      def cancel_running_attempts!(completed_at)
        running_attempts.each do |attempt|
          attempt.update!(
            status: "cancelled",
            **Support.completion_clock(attempt.started_at, completed_at),
            retryable: false,
            error_category: "cancelled",
            error_code: "stream_cancelled",
            error_message: "Stream consumption was cancelled."
          )
        end
      end

      def running_attempts
        if active_run
          active_run.attempts.where(status: "running")
        else
          Array(active_attempt).select { |attempt| attempt.status == "running" }
        end
      end

      def cancel_active_run!(completed_at)
        return unless active_run&.status == "running"

        active_run.update!(
          status: "cancelled",
          **Support.completion_clock(active_run.started_at, completed_at),
          error_category: "cancelled",
          error_code: "stream_cancelled",
          error_message: "Stream consumption was cancelled."
        )
      end

      def cancel_custom_tool_invocations!
        return unless active_run && defined?(RecordingStudioAI::CustomToolInvocation)

        active_run.custom_tool_invocations.find_each do |invocation|
          next if RecordingStudioAI::CustomToolInvocation.terminal_statuses.include?(invocation.status)

          completed_at = Time.current
          invocation.update!(
            status: "cancelled",
            completed_at: completed_at,
            latency_ms: invocation.started_at ? Support.elapsed_ms(invocation.started_at, completed_at) : nil,
            error_category: "cancelled",
            error_code: "stream_cancelled",
            error_message: "Stream consumption was cancelled."
          )
        end
      end
    end
  end
end
