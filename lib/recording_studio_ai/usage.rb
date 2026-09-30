# frozen_string_literal: true

module RecordingStudioAI
  module Usage
    module_function

    def spend!(attempt:, attribution:, operation:, purpose: nil)
      handler = RecordingStudioAI.configuration.usage_handler
      return if handler.nil?

      key = usage_key(attempt, attribution: attribution, operation: operation, purpose: purpose)
      return if key.nil?

      handler.call(**usage_arguments(key, attempt, attribution: attribution, operation: operation, purpose: purpose))
      nil
    end

    def usage_arguments(key, attempt, attribution:, operation:, purpose:)
      {
        key: key,
        quantity: 1,
        attribution: attribution,
        idempotency_key: "ai-attempt:#{attempt.id}",
        metadata: usage_metadata(attempt, operation: operation, purpose: purpose)
      }
    end

    def usage_key(attempt, attribution:, operation:, purpose:)
      resolver = RecordingStudioAI.configuration.usage_key_resolver
      require_resolver!(resolver)
      require_attempt_id!(attempt)
      normalize_usage_key(
        resolve_usage_key(resolver, attempt, attribution: attribution, operation: operation, purpose: purpose)
      )
    end

    def resolve_usage_key(resolver, attempt, attribution:, operation:, purpose:)
      resolver.call(
        attribution: attribution,
        operation: operation.to_s,
        provider: attempt.provider.to_s,
        model: attempt.model.to_s,
        profile: attempt.profile_key&.to_s,
        purpose: purpose
      )
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

    def usage_metadata(attempt, operation:, purpose:)
      {
        operation: operation.to_s,
        provider: attempt.provider.to_s,
        model: attempt.model.to_s,
        profile: attempt.profile_key&.to_s,
        purpose: purpose,
        ai_run_id: attempt.run_id,
        attempt_id: attempt.id,
        attempt_kind: attempt.kind
      }.freeze
    end

    def require_resolver!(resolver)
      return if resolver.respond_to?(:call)

      configuration_error!("usage_key_resolver must respond to call")
    end

    def require_attempt_id!(attempt)
      return if attempt.id

      request_error!("attempt id is required")
    end

    def configuration_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "configuration")
    end

    def request_error!(message)
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
    end

    private_class_method :usage_arguments, :usage_key, :resolve_usage_key, :normalize_usage_key, :usage_metadata,
                         :require_resolver!, :require_attempt_id!, :configuration_error!, :request_error!
  end
end
