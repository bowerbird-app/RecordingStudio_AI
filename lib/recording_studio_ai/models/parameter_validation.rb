# frozen_string_literal: true

module RecordingStudioAI
  module Models
    # Validates flat generation parameters (temperature, verbosity, etc.) against
    # a model definition when one is known, or performs type-only checks when the
    # resolved model is not yet available.
    module ParameterValidation
      module_function

      def normalize!(definition, parameters)
        provided = parameters.transform_keys(&:to_sym).compact
        unknown = provided.keys - Definition::KNOWN_PARAMETERS
        validation_error!("unknown generation parameters: #{unknown.join(', ')}") if unknown.any?

        Definition::KNOWN_PARAMETERS.to_h do |name|
          value = provided[name]
          next [name, nil] if value.nil?

          unless definition.supports_parameter?(name)
            validation_error!("parameter #{name} is not supported by #{definition.provider}/#{definition.model}")
          end

          [name, normalize_value!(name, value, definition.parameter(name))]
        end
      end

      def normalize_without_definition!(parameters)
        provided = parameters.transform_keys(&:to_sym).compact
        unknown = provided.keys - Definition::KNOWN_PARAMETERS
        validation_error!("unknown generation parameters: #{unknown.join(', ')}") if unknown.any?

        Definition::KNOWN_PARAMETERS.to_h do |name|
          value = provided[name]
          next [name, nil] if value.nil?

          [name, coerce_value!(name, value)]
        end
      end

      def normalize_value!(name, value, spec)
        coerced = coerce_value!(name, value)
        if spec[:values]
          allowed = spec[:values].map(&:to_s)
          unless allowed.include?(coerced.to_s)
            validation_error!("parameter #{name} must be one of: #{allowed.join(', ')}")
          end
          return coerced.to_s
        end

        validation_error!("parameter #{name} must be >= #{spec[:min]}") if spec.key?(:min) && coerced < spec[:min]
        validation_error!("parameter #{name} must be <= #{spec[:max]}") if spec.key?(:max) && coerced > spec[:max]

        coerced
      end

      def coerce_value!(name, value)
        case name
        when :temperature
          validation_error!("parameter temperature must be a Number") unless value.is_a?(Numeric)
          value.to_f
        when :max_output_tokens
          unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A-?\d+\z/))
            validation_error!("parameter max_output_tokens must be an Integer")
          end
          Integer(value)
        when :verbosity, :reasoning_effort
          validation_error!("parameter #{name} must be a String") unless value.is_a?(String) || value.is_a?(Symbol)
          value.to_s
        else
          value
        end
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
