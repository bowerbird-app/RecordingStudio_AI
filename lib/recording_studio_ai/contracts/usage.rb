# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    class Usage
      TOKEN_FIELDS = %i[
        input_tokens
        output_tokens
        total_tokens
        cached_input_tokens
        reasoning_tokens
      ].freeze

      attr_reader(*TOKEN_FIELDS)

      def initialize(**kwargs)
        TOKEN_FIELDS.each do |field|
          value = kwargs[field]
          instance_variable_set("@#{field}", value)
          validate_non_negative_integer!(field, value)
        end
      end

      def to_h
        TOKEN_FIELDS.each_with_object({}) do |field, result|
          result[field] = public_send(field)
        end
      end

      private

      def validate_non_negative_integer!(field, value)
        return if value.nil?
        return if value.is_a?(Integer) && value >= 0

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{field} must be a non-negative integer",
          code: "invalid_request"
        )
      end
    end
  end
end
