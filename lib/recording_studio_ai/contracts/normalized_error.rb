# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class NormalizedError
      CATEGORIES = %w[
        authentication
        authorization
        invalid_request
        unsupported_capability
        rate_limit
        timeout
        connection
        provider_unavailable
        provider_error
        content_policy
        invalid_response
        schema_validation
        attachment_validation
        custom_tool_not_found
        custom_tool_validation
        custom_tool_denied
        custom_tool_confirmation_required
        custom_tool_rejected
        custom_tool_failed
        batch_submission
        batch_expired
        cancelled
        configuration
        internal
      ].freeze

      attr_reader :category, :code, :message, :provider, :provider_code

      def initialize(category:, code:, message:, retryable: false, provider: nil, provider_code: nil)
        @category = category.to_s
        @code = code.to_s
        @message = message.to_s
        @retryable = !!retryable
        @provider = provider
        @provider_code = provider_code

        validate!
      end

      def retryable?
        @retryable
      end

      def to_h
        {
          category: category,
          code: code,
          message: message,
          retryable: retryable?,
          provider: provider,
          provider_code: provider_code
        }
      end

      private

      def validate!
        return if CATEGORIES.include?(category)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "error category must be one of: #{CATEGORIES.join(', ')}",
          code: "invalid_request"
        )
      end
    end
  end
end
