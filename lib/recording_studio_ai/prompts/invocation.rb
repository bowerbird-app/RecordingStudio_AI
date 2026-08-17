# frozen_string_literal: true

module RecordingStudioAI
  module Prompts
    class NamespaceProxy
      def initialize(registry, namespace)
        @registry = registry
        @namespace = namespace
      end

      def method_missing(key, ...)
        Invocation.new(@registry.fetch(@namespace, key) || missing_prompt!(key)).call(...)
      end

      def respond_to_missing?(key, include_private = false)
        @registry.fetch(@namespace, key).present? || super
      end

      private

      def missing_prompt!(key)
        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "prompt #{@namespace}.#{key} is not registered",
          code: "invalid_request"
        )
      end
    end

    class MethodProxy
      def initialize(registry)
        @registry = registry
      end

      def method_missing(namespace, ...)
        return NamespaceProxy.new(@registry, namespace) if (definition = @registry.all.find { |item| item.namespace == namespace.to_s }) && definition

        super
      end

      def respond_to_missing?(namespace, include_private = false)
        @registry.all.any? { |definition| definition.namespace == namespace.to_s } || super
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

      def stream(inputs:, **options, &block)
        RecordingStudioAI.generate(**request(inputs, options).merge(stream: true), &block)
      end

      def stream!(inputs:, **options, &block)
        RecordingStudioAI.generate!(**request(inputs, options).merge(stream: true), &block)
      end

      private

      def request(inputs, options)
        defaults = @definition.defaults.symbolize_keys
        supplied_tools = options.delete(:custom_tools)
        if supplied_tools && supplied_tools != resolved_tools
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "registered prompt custom tools cannot be overridden",
            code: "invalid_request"
          )
        end

        defaults.merge(options).merge(
          messages: @definition.render(inputs),
          custom_tools: resolved_tools,
          prompt_definition: @definition
        )
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