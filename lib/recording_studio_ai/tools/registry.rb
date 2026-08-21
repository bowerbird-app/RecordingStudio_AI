# frozen_string_literal: true

module RecordingStudioAI
  module Tools
    class Registry
      include RecordingStudioAI::RegistryLookup

      def initialize
        @definitions = {}
      end

      def register(override: false, **attributes)
        definition = RecordingStudioAI::Tools::Definition.new(**attributes)
        key = storage_key(definition.key, definition.version)
        if @definitions.key?(key) && !override
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool #{definition.key} version #{definition.version} is already registered",
            code: "invalid_request"
          )
        end

        @definitions[key] = definition
        definition
      end

      def fetch(key, version: nil)
        fetch_by_key_version(key, version: version)
      end

      def all
        sorted_all
      end
    end
  end
end
