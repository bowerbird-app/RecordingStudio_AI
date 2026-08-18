# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class Response
      OPERATIONS = %w[generation stream batch_submit batch_refresh batch_cancel].freeze

      attr_reader :operation, :purpose, :profile, :provider, :model, :run, :usage, :cost, :attempts, :error, :metadata

      def initialize(
        operation:,
        purpose: nil,
        profile: :medium,
        provider: nil,
        model: nil,
        run: nil,
        usage: nil,
        cost: nil,
        attempts: [],
        error: nil,
        metadata: {}
      )
        @operation = operation.to_s
        @purpose = purpose
        @profile = profile&.to_sym
        @provider = provider
        @model = model
        @run = run
        @usage = usage
        @cost = cost
        @attempts = attempts
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "response.metadata")

        validate!
      end

      def success?
        error.nil?
      end

      def to_h
        {
          success: success?,
          operation: operation,
          purpose: purpose,
          profile: profile,
          provider: provider,
          model: model,
          run: run_payload(run),
          usage: usage&.to_h,
          cost: cost&.to_h,
          attempts: attempts.map(&:to_h),
          error: error&.to_h,
          metadata: metadata
        }
      end

      private

      def validate!
        unless OPERATIONS.include?(operation)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "operation must be one of: #{OPERATIONS.join(', ')}",
            code: "invalid_request"
          )
        end

        unless profile.nil? || RecordingStudioAI::Contracts::RequestValidation::PROFILES.include?(profile)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "profile must be one of: #{RecordingStudioAI::Contracts::RequestValidation::PROFILES.join(', ')}",
            code: "invalid_request"
          )
        end

        unless usage.nil? || usage.is_a?(RecordingStudioAI::Contracts::Usage)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "usage must be a RecordingStudioAI::Contracts::Usage",
            code: "invalid_request"
          )
        end

        unless cost.nil? || cost.is_a?(RecordingStudioAI::Contracts::Cost)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "cost must be a RecordingStudioAI::Contracts::Cost",
            code: "invalid_request"
          )
        end

        unless attempts.all? { |item| item.is_a?(RecordingStudioAI::Contracts::AttemptSummary) }
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "attempts must contain only RecordingStudioAI::Contracts::AttemptSummary items",
            code: "invalid_request"
          )
        end

        return if error.nil? || error.is_a?(RecordingStudioAI::Contracts::NormalizedError)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "error must be a RecordingStudioAI::Contracts::NormalizedError",
          code: "invalid_request"
        )
      end

      def run_payload(run)
        return if run.nil?
        return { id: run.id } if run.respond_to?(:id)

        run
      end
    end
  end
end
