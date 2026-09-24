# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    # Outcome of RecordingStudioAI.perform_tool. Pending confirmation is a
    # status, not a failed execution.
    class ToolPerformance
      STATUSES = %w[completed awaiting_confirmation failed rejected denied cancelled].freeze

      attr_reader :status, :result, :error, :run

      def initialize(status:, result:, error:, run:)
        @status = status.to_s
        @result = result
        @error = error
        @run = run
        validate!
      end

      def success?
        status == "completed" && error.nil?
      end

      def awaiting_confirmation?
        status == "awaiting_confirmation"
      end

      private

      def validate!
        validate_status!
        validate_error!
      end

      def validate_status!
        return if STATUSES.include?(status)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool performance status must be one of: #{STATUSES.join(', ')}",
          code: "invalid_request"
        )
      end

      def validate_error!
        return if error.nil? || error.is_a?(RecordingStudioAI::Contracts::NormalizedError)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool performance error must be a normalized error",
          code: "invalid_request"
        )
      end
    end
  end
end
