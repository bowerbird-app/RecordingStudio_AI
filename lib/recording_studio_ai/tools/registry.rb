# frozen_string_literal: true

module RecordingStudioAI
  module Tools
    class Registry
      def initialize
        @definitions = {}
      end

      def register(**)
        definition = RecordingStudioAI::Tools::Definition.new(**)
        key = storage_key(definition.key, definition.version)
        if @definitions.key?(key)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "tool #{definition.key} version #{definition.version} is already registered",
            code: "invalid_request"
          )
        end

        @definitions[key] = definition
        definition
      end

      def fetch(key, version: nil)
        key = key.to_s

        return @definitions[storage_key(key, version)] if version

        candidates = @definitions.values.select { |definition| definition.key == key }
        candidates.max_by(&:version)
      end

      def all
        @definitions.values.sort_by { |definition| [definition.key, definition.version] }
      end

      private

      def storage_key(key, version)
        "#{key}:#{version}"
      end
    end
  end
end
