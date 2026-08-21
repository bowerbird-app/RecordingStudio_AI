# frozen_string_literal: true

module RecordingStudioAI
  # Shared normalization for fallback hop entries used by generate(fallbacks:)
  # and config.model_fallbacks. Each entry needs provider + model; optional
  # generation parameters are hop-only overlays (caller overrides still win).
  module FallbackEntries
    ENTRY_KEYS = (
      %i[provider model] + Models::Definition::KNOWN_PARAMETERS
    ).freeze

    module_function

    def normalize_list!(entries, path:)
      unless entries.is_a?(Array) && !entries.empty?
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} must be a non-empty Array",
          code: "invalid_request"
        )
      end

      entries.map.with_index { |entry, index| normalize_entry!(entry, path: "#{path}[#{index}]") }
    end

    def normalize_entry!(entry, path:)
      normalized = symbolize_entry!(entry, path: path)
      {
        provider: require_value!(normalized[:provider], path: "#{path}.provider"),
        model: require_model!(normalized[:model], path: "#{path}.model"),
        **optional_parameters!(normalized)
      }
    end

    def parameter_overrides_from(entry)
      Models::Definition::KNOWN_PARAMETERS.index_with { |name| entry[name] }.compact
    end

    def symbolize_entry!(entry, path:)
      unless entry.is_a?(Hash)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} must be a Hash",
          code: "invalid_request"
        )
      end

      normalized = entry.transform_keys(&:to_sym)
      reject_unknown_entry_keys!(normalized, path: path)
      normalized
    end

    def reject_unknown_entry_keys!(normalized, path:)
      unknown = normalized.keys - ENTRY_KEYS
      return if unknown.empty?

      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "#{path} contains unknown keys: #{unknown.join(', ')}",
        code: "invalid_request"
      )
    end

    def require_value!(value, path:)
      if value.nil? || value.to_s.strip.empty?
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} is required",
          code: "invalid_request"
        )
      end

      value.to_sym
    end

    def require_model!(value, path:)
      if value.nil? || value.to_s.strip.empty?
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "#{path} is required",
          code: "invalid_request"
        )
      end

      value.to_s.strip
    end

    def optional_parameters!(normalized)
      parameters = parameter_overrides_from(normalized)
      return {} if parameters.empty?

      Models::ParameterValidation.normalize_without_definition!(parameters).compact
    end
  end
end
