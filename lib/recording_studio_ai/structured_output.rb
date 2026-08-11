# frozen_string_literal: true

require "json"
require "json_schemer"

module RecordingStudioAI
  module StructuredOutput
    module_function

    def validate_schema!(schema)
      return nil if schema.nil?

      unless schema.is_a?(Hash)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "schema must be a JSON Schema Hash",
          code: "invalid_request"
        )
      end

      normalized = RecordingStudioAI::Contracts::Containment.ensure_serializable!(schema, path: "schema")
      unless JSONSchemer.valid_schema?(normalized)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "schema is not a valid JSON Schema",
          code: "invalid_request"
        )
      end
      JSONSchemer.schema(normalized)
      normalized
    end

    def apply(result, schema:, provider:)
      return result unless schema && result.success?

      data = JSON.parse(result.text.to_s)
      errors = JSONSchemer.schema(schema).validate(data).to_a
      return result.with(structured_data: data) if errors.empty?

      result.with(structured_data: nil, error: validation_error(provider))
    rescue JSON::ParserError
      result.with(structured_data: nil, error: validation_error(provider))
    end

    def validation_error(provider)
      RecordingStudioAI::Contracts::NormalizedError.new(
        category: "schema_validation",
        code: "schema_validation",
        message: "Provider output did not match the requested schema.",
        retryable: false,
        provider: provider.to_s
      )
    end
  end
end
