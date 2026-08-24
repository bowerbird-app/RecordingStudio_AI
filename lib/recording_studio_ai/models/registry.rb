# frozen_string_literal: true

module RecordingStudioAI
  module Models
    # Stores registered model definitions keyed by provider + model key. Profiles
    # reference models by their provider API model string, so lookups accept both
    # the stable key (matching the registration filename) and the model string.
    class Registry
      def initialize
        @definitions = {}
      end

      def register(override: false, **attributes)
        definition = RecordingStudioAI::Models::Definition.new(**attributes)
        storage = storage_key(definition.provider, definition.key)

        if @definitions.key?(storage) && !override
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "model #{definition.provider}/#{definition.key} is already registered",
            code: "invalid_request"
          )
        end

        @definitions[storage] = definition
        definition
      end

      # Look up a definition by its provider and either its registered key or its
      # provider API model string. Profiles use the model string.
      def fetch(provider, key_or_model)
        provider = provider.to_sym
        identifier = key_or_model.to_s

        @definitions[storage_key(provider, identifier)] ||
          @definitions.values.find do |definition|
            definition.provider == provider && definition.model == identifier
          end
      end

      def fetch_by_key(provider, key)
        @definitions[storage_key(provider.to_sym, key.to_s)]
      end

      def registered?(provider, key_or_model)
        !fetch(provider, key_or_model).nil?
      end

      def all
        @definitions.values.sort_by { |definition| [definition.provider.to_s, definition.key] }
      end

      def for_provider(provider)
        provider = provider.to_sym
        all.select { |definition| definition.provider == provider }
      end

      def clear
        @definitions = {}
      end

      private

      def storage_key(provider, key)
        "#{provider}:#{key}"
      end
    end
  end
end
