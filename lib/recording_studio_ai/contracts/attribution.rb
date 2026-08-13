# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class Attribution
      INITIATOR_KINDS = %w[user agent service system].freeze
      EXECUTION_SOURCES = %w[web api admin job scheduled webhook console system].freeze

      attr_reader :root_recording, :context_recording, :initiator, :initiator_kind,
                  :executor, :impersonator, :execution_source, :request_id, :job_id

      def initialize(
        root_recording:,
        initiator:,
        initiator_kind: nil,
        context_recording: nil,
        executor: nil,
        impersonator: nil,
        execution_source: nil,
        request_id: nil,
        job_id: nil
      )
        @root_recording = root_recording
        @context_recording = context_recording
        @initiator = initiator
        @initiator_kind = normalize_initiator_kind(initiator_kind)
        @executor = executor
        @impersonator = impersonator
        @execution_source = execution_source&.to_s
        @request_id = request_id&.to_s
        @job_id = job_id&.to_s

        validate!
      end

      def to_h
        {
          root_recording_id: extract_identifier(root_recording),
          context_recording_id: extract_identifier(context_recording),
          initiator_id: extract_identifier(initiator),
          initiator_kind: initiator_kind,
          executor_id: extract_identifier(executor),
          impersonator_id: extract_identifier(impersonator),
          execution_source: execution_source,
          request_id: request_id,
          job_id: job_id
        }
      end

      private

      def normalize_initiator_kind(kind)
        return "user" if kind.nil?

        kind.to_s
      end

      def validate!
        if root_recording.nil?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "root_recording is required",
            code: "invalid_request"
          )
        end

        if initiator.nil?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "initiator is required",
            code: "invalid_request"
          )
        end

        unless INITIATOR_KINDS.include?(initiator_kind)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "initiator_kind must be one of: #{INITIATOR_KINDS.join(', ')}",
            code: "invalid_request"
          )
        end

        validate_recording_tenancy!

        return if execution_source.nil? || EXECUTION_SOURCES.include?(execution_source)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "execution_source must be one of: #{EXECUTION_SOURCES.join(', ')}",
          code: "invalid_request"
        )
      end

      def validate_recording_tenancy!
        RecordingStudioAI.configuration.attribution_validator.call(
          root_recording: root_recording,
          context_recording: context_recording
        )
      rescue ArgumentError => error
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          error.message,
          code: "invalid_request"
        )
      end

      def extract_identifier(value)
        return nil if value.nil?

        return value.id if value.respond_to?(:id)

        value.object_id
      end
    end
  end
end
