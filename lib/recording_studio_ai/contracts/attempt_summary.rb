# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class AttemptSummary
      KINDS = %w[primary retry fallback continuation].freeze
      STATUSES = %w[pending running completed failed cancelled].freeze

      attr_reader :sequence, :kind, :provider, :model, :status, :usage, :cost, :latency, :finish_reason, :error

      def initialize(
        sequence:,
        kind:,
        status:, provider: nil,
        model: nil,
        usage: nil,
        cost: nil,
        latency: nil,
        finish_reason: nil,
        error: nil
      )
        @sequence = sequence
        @kind = kind.to_s
        @provider = provider
        @model = model
        @status = status.to_s
        @usage = usage
        @cost = cost
        @latency = latency
        @finish_reason = finish_reason
        @error = error

        validate!
      end

      def to_h
        {
          sequence: sequence,
          kind: kind,
          provider: provider,
          model: model,
          status: status,
          usage: usage&.to_h,
          cost: cost&.to_h,
          latency: latency,
          finish_reason: finish_reason,
          error: error&.to_h
        }
      end

      private

      def validate!
        unless sequence.is_a?(Integer) && sequence.positive?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "sequence must be a positive integer",
            code: "invalid_request"
          )
        end

        unless KINDS.include?(kind)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "kind must be one of: #{KINDS.join(', ')}",
            code: "invalid_request"
          )
        end

        unless STATUSES.include?(status)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "status must be one of: #{STATUSES.join(', ')}",
            code: "invalid_request"
          )
        end

        return if latency.nil? || (latency.is_a?(Integer) && latency >= 0)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "latency must be a non-negative integer",
          code: "invalid_request"
        )
      end
    end
  end
end
