# frozen_string_literal: true

module RecordingStudioAI
  module Contracts
    module Containment
      module_function

      def ensure_serializable!(value, path: "value")
        case value
        when NilClass, TrueClass, FalseClass, String, Integer, Float
          value
        when Symbol
          value.to_s
        when Array
          value.map.with_index { |item, index| ensure_serializable!(item, path: "#{path}[#{index}]") }
        when Hash
          value.each_with_object({}) do |(key, item), result|
            unless key.is_a?(String) || key.is_a?(Symbol)
              raise RecordingStudioAI::Errors::ContractValidationError.new(
                "#{path} must use String or Symbol keys",
                code: "invalid_request"
              )
            end

            normalized_key = key.to_s
            result[normalized_key] = ensure_serializable!(item, path: "#{path}.#{normalized_key}")
          end
        else
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "#{path} must be composed of primitive JSON-like values",
            code: "invalid_request"
          )
        end
      end
    end
  end
end
