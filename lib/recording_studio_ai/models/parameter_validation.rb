# frozen_string_literal: true

module RecordingStudioAI
  module Models
    # Validates flat generation parameters (temperature, verbosity, etc.) against
    # a model definition when one is known, or performs type-only checks when the
    # resolved model is not yet available.
    module ParameterValidation
      # Fallback types used when provider+model are not yet resolved to a registry
      # definition. Built-in registrations always declare their own type.
      FALLBACK_TYPES = {
        temperature: :number,
        max_output_tokens: :integer,
        verbosity: :string,
        reasoning_effort: :string
      }.freeze

      module_function

      def normalize!(definition, parameters)
        provided = compact_known_parameters!(parameters)

        Definition::KNOWN_PARAMETERS.to_h do |name|
          value = provided[name]
          next [name, nil] if value.nil?

          unless definition.supports_parameter?(name)
            validation_error!("parameter #{name} is not supported by #{definition.provider}/#{definition.model}")
          end

          [name, normalize_value!(name, value, definition.parameter(name))]
        end
      end

      # Soft application of caller overrides for a candidate hop. Keeps a value when
      # the model supports it (clamped to that model's range). Omits it when the
      # model does not support it or when an enum value is not allowed. Does not
      # raise for unsupported parameters — use +normalize!+ when a pinned model
      # must reject them at request time.
      def adapt_for_model(definition, parameters)
        provided = compact_known_parameters!(parameters)

        Definition::KNOWN_PARAMETERS.to_h do |name|
          value = provided[name]
          next [name, nil] if value.nil? || !definition.supports_parameter?(name)

          [name, adapt_value(name, value, definition.parameter(name))]
        end
      end

      def normalize_without_definition!(parameters)
        provided = compact_known_parameters!(parameters)

        Definition::KNOWN_PARAMETERS.to_h do |name|
          value = provided[name]
          next [name, nil] if value.nil?

          [name, coerce_value!(name, value, FALLBACK_TYPES.fetch(name))]
        end
      end

      def compact_known_parameters!(parameters)
        provided = parameters.transform_keys(&:to_sym).compact
        unknown = provided.keys - Definition::KNOWN_PARAMETERS
        validation_error!("unknown generation parameters: #{unknown.join(', ')}") if unknown.any?
        provided
      end

      def normalize_value!(name, value, spec)
        apply_parameter_constraints!(name, value, spec, policy: :raise)
      end

      def adapt_value(name, value, spec)
        apply_parameter_constraints!(name, value, spec, policy: :adapt)
      end

      def apply_parameter_constraints!(name, value, spec, policy:)
        coerced = coerce_value!(name, value, spec.fetch(:type))
        if spec[:values]
          allowed = spec[:values].map(&:to_s)
          return coerced.to_s if allowed.include?(coerced.to_s)

          return nil if policy == :adapt

          validation_error!("parameter #{name} must be one of: #{allowed.join(', ')}")
        end

        if policy == :adapt
          coerced = spec[:min] if spec.key?(:min) && coerced < spec[:min]
          coerced = spec[:max] if spec.key?(:max) && coerced > spec[:max]
          return coerced
        end

        validation_error!("parameter #{name} must be >= #{spec[:min]}") if spec.key?(:min) && coerced < spec[:min]
        validation_error!("parameter #{name} must be <= #{spec[:max]}") if spec.key?(:max) && coerced > spec[:max]

        coerced
      end

      def coerce_value!(name, value, type)
        case type.to_sym
        when :number
          validation_error!("parameter #{name} must be a Number") unless value.is_a?(Numeric)
          value.to_f
        when :integer
          unless value.is_a?(Integer) || (value.is_a?(String) && value.match?(/\A-?\d+\z/))
            validation_error!("parameter #{name} must be an Integer")
          end
          Integer(value)
        when :string
          validation_error!("parameter #{name} must be a String") unless value.is_a?(String) || value.is_a?(Symbol)
          value.to_s
        else
          validation_error!("parameter #{name} has unknown type: #{type}")
        end
      end

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
