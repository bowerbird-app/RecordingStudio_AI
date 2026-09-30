# frozen_string_literal: true

require "recording_studio_ai/usage/event"

module RecordingStudioAI
  module Usage
    DECLINED_CATEGORY = "usage"
    DECLINED_CODE = "usage_declined"
    MESSAGE_LIMIT = 255

    module_function

    def spend!(attempt:, attribution:, operation:, purpose: nil, provider_native_tools: [])
      charge!(
        Event.for_attempt(
          attempt,
          attribution: attribution,
          operation: operation,
          purpose: purpose,
          provider_native_tools: provider_native_tools
        )
      )
    end

    def spend_batch_submission!(batch:, attribution:, provider_native_tools:)
      charge!(Event.for_batch_submission(batch, attribution: attribution, provider_native_tools: provider_native_tools))
    end

    def charge!(event)
      handler = RecordingStudioAI.configuration.usage_handler
      return if handler.nil?

      event.require_subject_id!
      key = usage_key(event)
      return if key.nil?

      handler.call(**event.handler_arguments(key))
      nil
    end

    def usage_key(event)
      resolver = RecordingStudioAI.configuration.usage_key_resolver
      require_resolver!(resolver)
      normalize_usage_key(resolve_usage_key(resolver, event))
    end

    def resolve_usage_key(resolver, event)
      resolver.call(**event.resolver_arguments)
    end

    def normalize_usage_key(key)
      return if key.nil?

      unless key.is_a?(String) || key.is_a?(Symbol)
        configuration_error!("usage_key_resolver must return a String, Symbol, or nil")
      end

      normalized = key.to_s
      return normalized unless normalized.blank?

      configuration_error!("usage_key_resolver returned a blank key")
    end

    def normalize_provider_native_tools(tools)
      Array(tools).map(&:to_sym).uniq.freeze
    end

    def require_resolver!(resolver)
      return if resolver.respond_to?(:call)

      configuration_error!("usage_key_resolver must respond to call")
    end

    def configuration_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "configuration")
    end

    def request_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
    end

    private_class_method :charge!, :usage_key, :resolve_usage_key, :normalize_usage_key,
                         :normalize_provider_native_tools, :require_resolver!,
                         :configuration_error!, :request_error!
  end
end
