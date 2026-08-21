# frozen_string_literal: true

module RecordingStudioAI
  module Prompts
    class MethodProxy
      def initialize(registry)
        @registry = registry
      end

      def method_missing(key, ...)
        definition = @registry.fetch(key)
        return Invocation.new(definition).public_send(...) if definition

        super
      end

      def respond_to_missing?(key, include_private = false)
        @registry.fetch(key).present? || super
      end
    end

    class Invocation
      def initialize(definition)
        @definition = definition
      end

      def call(inputs:, **options)
        RecordingStudioAI.generate(**request(inputs, options))
      end

      def call!(inputs:, **options)
        RecordingStudioAI.generate!(**request(inputs, options))
      end

      def stream(inputs:, **options, &)
        RecordingStudioAI.generate(**request(inputs, options).merge(stream: true), &)
      end

      def stream!(inputs:, **options, &)
        RecordingStudioAI.generate!(**request(inputs, options).merge(stream: true), &)
      end

      private

      def request(inputs, options)
        defaults = @definition.defaults.symbolize_keys
        supplied_tools = options.delete(:custom_tools)

        defaults.merge(options).merge(
          messages: @definition.render(inputs),
          custom_tools: merge_custom_tools(supplied_tools),
          prompt_definition: @definition
        )
      end

      def merge_custom_tools(supplied_tools)
        return resolved_tools if supplied_tools.nil?

        unless supplied_tools.is_a?(Array)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "custom_tools must be an Array",
            code: "invalid_request"
          )
        end

        # Prompt tools first, then caller tools. Same key is replaced by the
        # caller entry (request validation forbids duplicate keys). Identical
        # key+version is a no-op. Unknown refs still fail via tools.fetch.
        by_key = {}
        order = []

        (resolved_tools + normalize_tool_refs(supplied_tools)).each do |reference|
          key = reference.fetch(:key)
          unless by_key.key?(key)
            order << key
          end
          by_key[key] = reference
        end

        order.map { |key| by_key.fetch(key) }
      end

      def normalize_tool_refs(references)
        references.map.with_index do |reference, index|
          unless reference.is_a?(Hash)
            raise RecordingStudioAI::Errors::ContractValidationError.new(
              "custom_tools[#{index}] must be a Hash",
              code: "invalid_request"
            )
          end

          normalized = reference.transform_keys(&:to_sym)
          key = normalized[:key]
          version = normalized[:version]
          definition = RecordingStudioAI.tools.fetch(key, version: version)
          unless definition
            raise RecordingStudioAI::Errors::ContractValidationError.new(
              "registered prompt tool #{key} is not registered",
              code: "invalid_request"
            )
          end

          { key: definition.key, version: definition.version }
        end
      end

      def resolved_tools
        @resolved_tools ||= @definition.tools.map do |tool|
          definition = RecordingStudioAI.tools.fetch(tool.fetch(:key), version: tool[:version])
          unless definition
            raise RecordingStudioAI::Errors::ContractValidationError.new(
              "registered prompt tool #{tool.fetch(:key)} is not registered",
              code: "invalid_request"
            )
          end

          { key: definition.key, version: definition.version }
        end
      end
    end
  end
end
