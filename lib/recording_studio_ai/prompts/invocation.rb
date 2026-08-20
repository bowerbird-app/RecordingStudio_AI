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
