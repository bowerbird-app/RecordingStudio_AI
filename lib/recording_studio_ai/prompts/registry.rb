# frozen_string_literal: true

module RecordingStudioAI
  module Prompts
    class Registry
      include RecordingStudioAI::RegistryLookup

      def initialize
        @definitions = {}
      end

      def register(override: false, **attributes)
        definition = RecordingStudioAI::Prompts::Definition.new(**attributes)
        storage = storage_key(definition.key, definition.version)
        existing = @definitions[storage]

        if existing && !override
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "prompt #{definition.key} version #{definition.version} is already registered",
            code: "invalid_request"
          )
        end

        if existing && override && !existing.overridable?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "prompt #{definition.key} version #{definition.version} is not overridable",
            code: "invalid_request"
          )
        end

        @definitions[storage] = definition
        definition
      end

      def fetch(key, version: nil)
        fetch_by_key_version(key, version: version)
      end

      def all
        sorted_all
      end

      def replace_owner(owner)
        owner = owner.to_s
        replacements = Registry.new
        yield replacements
        unless replacements.all.all? { |definition| definition.owner == owner }
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "replacement prompts must use owner #{owner}",
            code: "invalid_request"
          )
        end

        retained = @definitions.reject { |_key, definition| definition.owner == owner }
        additions = replacements.all.to_h { |definition| [storage_key(definition.key, definition.version), definition] }
        collisions = retained.keys & additions.keys
        if collisions.any?
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "replacement prompt conflicts with an existing registered prompt",
            code: "invalid_request"
          )
        end

        @definitions = retained.merge(additions)
      end
    end
  end
end
