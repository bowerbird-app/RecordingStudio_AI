# frozen_string_literal: true

module RecordingStudioAI
  module Tools
    class Definition
      COSTS = %w[negligible low medium high].freeze
      LATENCIES = %w[instant fast slow].freeze
      PARAMETER_TYPES = %w[string integer number boolean object array].freeze
      PARAMETER_KEYS = %i[name type required description allowed_values default].freeze

      attr_reader :key, :version, :name, :description, :use_when, :do_not_use_when,
                  :parameters, :returns, :cost, :latency, :read_only, :destructive,
                  :requires_confirmation, :idempotent, :examples, :executor_label, :executor

      def initialize(
        key:,
        version:,
        name:,
        description:,
        use_when:,
        do_not_use_when:,
        parameters:,
        returns:,
        cost:,
        latency:,
        read_only:,
        destructive:,
        requires_confirmation:,
        idempotent:,
        executor_label:,
        executor:,
        examples: nil
      )
        @key = key.to_s
        @version = version
        @name = name.to_s
        @description = description.to_s
        @use_when = use_when.to_s
        @do_not_use_when = do_not_use_when.to_s
        @parameters = normalize_parameters(parameters)
        @returns = returns.to_s
        @cost = cost.to_s
        @latency = latency.to_s
        @read_only = read_only
        @destructive = destructive
        @requires_confirmation = requires_confirmation
        @idempotent = idempotent
        @examples = examples.nil? ? nil : RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          examples,
          path: "tool.examples"
        )
        @executor_label = executor_label.to_s
        @executor = executor

        validate!
      end

      def validate_arguments!(arguments)
        unless arguments.is_a?(Hash)
          validation_error!("custom tool arguments must be a Hash")
        end

        normalized = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
          arguments,
          path: "custom_tool.arguments"
        )
        definitions = parameters.to_h { |parameter| [parameter.fetch(:name), parameter] }
        unknown = normalized.keys - definitions.keys
        validation_error!("custom tool arguments include unknown parameters") if unknown.any?

        definitions.each_with_object({}) do |(name, parameter), validated|
          if normalized.key?(name)
            value = normalized.fetch(name)
            validate_argument_value!(name, value, parameter)
            validated[name] = value
          elsif parameter.key?(:default)
            validated[name] = parameter.fetch(:default)
          elsif parameter.fetch(:required)
            validation_error!("missing required custom tool argument: #{name}")
          end
        end
      rescue RecordingStudioAI::Errors::ContractValidationError => error
        raise error if error.code == "custom_tool_validation"

        validation_error!(error.message)
      end

      def json_schema
        properties = parameters.to_h do |parameter|
          schema = {
            "type" => parameter.fetch(:type),
            "description" => parameter.fetch(:description)
          }
          schema["enum"] = parameter[:allowed_values] if parameter.key?(:allowed_values)
          schema["default"] = parameter[:default] if parameter.key?(:default)
          [parameter.fetch(:name), schema]
        end

        {
          "type" => "object",
          "properties" => properties,
          "required" => parameters.select { |parameter| parameter.fetch(:required) }.map { |parameter| parameter.fetch(:name) },
          "additionalProperties" => false
        }
      end

      def provider_description
        [description, "Use when: #{use_when}", "Do not use when: #{do_not_use_when}"].join("\n")
      end

      def to_h
        {
          key: key,
          version: version,
          name: name,
          description: description,
          use_when: use_when,
          do_not_use_when: do_not_use_when,
          parameters: parameters,
          returns: returns,
          cost: cost,
          latency: latency,
          read_only: read_only,
          destructive: destructive,
          requires_confirmation: requires_confirmation,
          idempotent: idempotent,
          examples: examples,
          executor_label: executor_label
        }
      end

      private

      def normalize_parameters(value)
        unless value.is_a?(Array)
          validation_error!("tool parameters must be an Array", code: "invalid_request")
        end

        names = []
        value.map.with_index do |parameter, index|
          unless parameter.is_a?(Hash)
            validation_error!("tool parameters[#{index}] must be a Hash", code: "invalid_request")
          end

          normalized = parameter.transform_keys(&:to_sym)
          unknown_keys = normalized.keys - PARAMETER_KEYS
          if unknown_keys.any?
            validation_error!("tool parameters[#{index}] has unknown keys: #{unknown_keys.join(', ')}", code: "invalid_request")
          end

          name = normalized[:name].to_s
          type = normalized[:type].to_s
          if name.empty? || !name.match?(/\A[a-z0-9_]+\z/)
            validation_error!("tool parameter name must be snake_case", code: "invalid_request")
          end
          validation_error!("tool parameter names must be unique", code: "invalid_request") if names.include?(name)
          unless PARAMETER_TYPES.include?(type)
            validation_error!("tool parameter type must be one of: #{PARAMETER_TYPES.join(', ')}", code: "invalid_request")
          end
          unless normalized.key?(:required) && [true, false].include?(normalized[:required])
            validation_error!("tool parameter required must be true or false", code: "invalid_request")
          end
          unless normalized[:description].is_a?(String) && !normalized[:description].strip.empty?
            validation_error!("tool parameter description must be a non-empty String", code: "invalid_request")
          end

          names << name
          result = normalized.merge(name: name, type: type)
          if result.key?(:allowed_values)
            unless result[:allowed_values].is_a?(Array) && !result[:allowed_values].empty?
              validation_error!("tool parameter allowed_values must be a non-empty Array", code: "invalid_request")
            end
            result[:allowed_values] = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
              result[:allowed_values], path: "tool.parameters[#{index}].allowed_values"
            )
            result[:allowed_values].each { |item| validate_argument_type!(name, item, type, code: "invalid_request") }
          end
          if result.key?(:default)
            result[:default] = RecordingStudioAI::Contracts::Containment.ensure_serializable!(
              result[:default], path: "tool.parameters[#{index}].default"
            )
            validate_argument_value!(name, result[:default], result, code: "invalid_request")
          end
          result.freeze
        end.freeze
      end

      def validate_argument_value!(name, value, parameter, code: "custom_tool_validation")
        validate_argument_type!(name, value, parameter.fetch(:type), code: code)
        return unless parameter.key?(:allowed_values) && !parameter.fetch(:allowed_values).include?(value)

        validation_error!("custom tool argument #{name} is not an allowed value", code: code)
      end

      def validate_argument_type!(name, value, type, code: "custom_tool_validation")
        valid = case type
                when "string" then value.is_a?(String)
                when "integer" then value.is_a?(Integer)
                when "number" then value.is_a?(Numeric)
                when "boolean" then value == true || value == false
                when "object" then value.is_a?(Hash)
                when "array" then value.is_a?(Array)
                end
        return if valid

        validation_error!("custom tool argument #{name} must be a #{type}", code: code)
      end

      def validation_error!(message, code: "custom_tool_validation")
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: code)
      end

      def validate!
        if key.empty? || key.length > RecordingStudioAI::Providers::ToolCall::MAX_KEY_LENGTH || !key.match?(/\A[a-z0-9_]+\z/)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool key must be snake_case",
            code: "invalid_request"
          )
        end

        unless version.is_a?(Integer) && version.positive?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool version must be a positive integer",
            code: "invalid_request"
          )
        end

        unless COSTS.include?(cost)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool cost must be one of: #{COSTS.join(', ')}",
            code: "invalid_request"
          )
        end

        unless LATENCIES.include?(latency)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool latency must be one of: #{LATENCIES.join(', ')}",
            code: "invalid_request"
          )
        end

        {
          name: name,
          description: description,
          use_when: use_when,
          do_not_use_when: do_not_use_when,
          returns: returns,
          executor_label: executor_label
        }.each do |field, value|
          next unless value.strip.empty?

          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool #{field} must be a non-empty String",
            code: "invalid_request"
          )
        end

        %i[read_only destructive requires_confirmation idempotent].each do |field|
          next if [true, false].include?(public_send(field))

          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool #{field} must be true or false",
            code: "invalid_request"
          )
        end

        if read_only && destructive
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "destructive tools cannot be read_only",
            code: "invalid_request"
          )
        end

        return if executor.respond_to?(:call)

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "tool executor must respond to call",
          code: "invalid_request"
        )
      end
    end
  end
end
