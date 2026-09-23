# frozen_string_literal: true

module RecordingStudioAI
  module Providers
    # Fields every provider operation reports, regardless of payload shape.
    # Generation adds text and tool data; decision adds typed answers.
    class ExecutionResult
      FIELDS = %i[usage cost provider_request_id error metadata retention_snapshot].freeze

      attr_reader(*FIELDS)

      def initialize(**attributes)
        unexpected = attributes.keys - FIELDS
        raise ArgumentError, "unknown result attributes: #{unexpected.join(', ')}" if unexpected.any?

        @usage = attributes[:usage]
        @cost = attributes[:cost]
        @provider_request_id = attributes[:provider_request_id]
        @error = attributes[:error]
        @metadata = sanitized_metadata(attributes[:metadata])
        @retention_snapshot = contained_snapshot(attributes[:retention_snapshot])
      end

      def success?
        error.nil?
      end

      protected

      def execution_attributes
        FIELDS.to_h { |field| [field, public_send(field)] }
      end

      private

      def sanitized_metadata(value)
        RecordingStudioAI::Metadata.sanitize!(value || {}, path: "provider_result.metadata")
      end

      def contained_snapshot(value)
        RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          value,
          path: "provider_result.retention_snapshot"
        )
      end
    end
  end
end
