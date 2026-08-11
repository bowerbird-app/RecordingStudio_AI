# frozen_string_literal: true

module RecordingStudioAI
  module Adapters
    class BatchResult
      STATUSES = %w[preparing submitted processing completed partially_completed failed cancelled expired].freeze

      attr_reader :provider_batch_id, :status, :items, :expires_at, :error, :metadata

      def initialize(status:, provider_batch_id: nil, items: [], expires_at: nil, error: nil, metadata: {})
        @provider_batch_id = provider_batch_id&.to_s
        @status = status.to_s
        @items = items
        @expires_at = expires_at
        @error = error
        @metadata = RecordingStudioAI::Metadata.sanitize!(metadata, path: "batch_result.metadata")
        validate!
      end

      def success? = error.nil?

      def with(**overrides)
        self.class.new(
          provider_batch_id: provider_batch_id, status: status, items: items,
          expires_at: expires_at, error: error, metadata: metadata, **overrides
        )
      end

      private

      def validate!
        valid_items = items.all? { |item| item.is_a?(BatchItemResult) }
        valid_error = error.nil? || error.is_a?(Contracts::NormalizedError)
        failure_has_error = !%w[failed expired].include?(status) || !error.nil?
        return if STATUSES.include?(status) && valid_items && valid_error && failure_has_error

        raise Errors::ContractValidationError.new("invalid adapter batch result", code: "invalid_request")
      end
    end
  end
end