# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class CancellationState
      attr_reader :deadline

      def initialize(deadline:)
        @deadline = deadline
        @cancelled = false
        @mutex = Mutex.new
      end

      def cancel!
        @mutex.synchronize { @cancelled = true }
      end

      def cancelled?
        @mutex.synchronize { @cancelled } || Time.current >= deadline
      end
    end

    CustomToolContext = Data.define(
      :root_recording,
      :context_recording,
      :initiator,
      :executor,
      :run,
      :requesting_attempt,
      :execution_source,
      :deadline,
      :cancellation_state
    )
  end
end
