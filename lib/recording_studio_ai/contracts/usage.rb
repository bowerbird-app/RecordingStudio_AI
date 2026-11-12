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

      KIND_FOR_FIELD = {
        input_tokens: :input,
        output_tokens: :output,
        cached_input_tokens: :cached_input,
        reasoning_tokens: :reasoning
      }.freeze

      attr_reader(*TOKEN_FIELDS, :counts)

      def initialize(counts: nil, **kwargs)
        extra = counts.to_h.transform_keys(&:to_sym)
        @counts = {}
        TOKEN_FIELDS.each do |field|
          kind = KIND_FOR_FIELD[field]
          value = kwargs.key?(field) ? kwargs[field] : (kind && extra[kind])
          instance_variable_set("@#{field}", value)
          validate_non_negative_integer!(field, value)
          @counts[kind] = value if kind && !value.nil?
        end
        extra.each do |kind, value|
          next if KIND_FOR_FIELD.value?(kind) || kind == :total

          validate_non_negative_integer!(kind, value)
          @counts[kind] = value unless value.nil?
        end
        @counts.freeze
      end

      def with_count(kind, value)
        self.class.new(**to_h, counts: counts.merge(kind.to_sym => value))
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
