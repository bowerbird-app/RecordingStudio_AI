# frozen_string_literal: true

module RecordingStudioAI
  module Orchestration
    class Persistence
      def initialize(configuration:)
        @configuration = configuration
        @runs = RunPersistence.new(configuration: configuration)
        @attempts = AttemptPersistence.new(configuration: configuration)
      end

      def create_run!(request, candidate, operation:)
        @runs.create!(request, candidate, operation: operation)
      end

      def create_attempt!(run, request, planned, sequence, kind)
        @attempts.create!(run, request, planned, sequence, kind)
      end

      def complete_attempt!(attempt, result)
        @attempts.complete!(attempt, result)
      end

      def complete_run!(run, executions, final_execution)
        @runs.complete!(run, executions, final_execution)
      end

      def complete_deadline_failure(request, run, operation:)
        @runs.complete_deadline_failure(request, run, operation: operation)
      end

      def aggregate_usage(executions)
        Aggregation.usage(executions)
      end

      def aggregate_cost(executions)
        Aggregation.cost(executions)
      end
    end
  end
end
