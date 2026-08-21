# frozen_string_literal: true

module RecordingStudioAI
  # Shared key/version lookup helpers for tools and prompts registries.
  # Register / override policy stays in each registry.
  module RegistryLookup
    private

    def storage_key(key, version)
      "#{key}:#{version}"
    end

    def fetch_by_key_version(key, version: nil)
      key = key.to_s
      return @definitions[storage_key(key, version)] if version

      @definitions.values.select { |definition| definition.key == key }.max_by(&:version)
    end

    def sorted_all
      @definitions.values.sort_by { |definition| [definition.key, definition.version] }
    end
  end
end
