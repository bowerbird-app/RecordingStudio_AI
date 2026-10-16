# frozen_string_literal: true

module RecordingStudioAI
  module Agents
    module Request
      ATTRIBUTION = %i[
        root_recording initiator context_recording executor impersonator
        initiator_kind execution_source request_id job_id
      ].freeze
      CREATE_KEYS = (
        %i[instructions input profile model provider idempotency_key purpose metadata] + ATTRIBUTION
      ).freeze
      INPUT_KEYS = (%i[session input idempotency_key purpose metadata] + ATTRIBUTION).freeze
      SESSION_KEYS = (%i[session purpose metadata] + ATTRIBUTION).freeze

      module_function

      def create!(**kwargs)
        build(kwargs, CREATE_KEYS, "hosted agent session") do |request|
          request[:instructions] = optional_string(kwargs[:instructions], "instructions")
          request[:input] = required_text(kwargs[:input], "input")
          request[:idempotency_key] = required_key(kwargs[:idempotency_key])
          assign_resolution!(request, kwargs)
        end
      end

      def input!(**kwargs)
        build(kwargs, INPUT_KEYS, "hosted agent input") do |request|
          request[:session] = session_record!(kwargs[:session])
          request[:input] = required_text(kwargs[:input], "input")
          request[:idempotency_key] = required_key(kwargs[:idempotency_key])
        end
      end

      def session!(**kwargs)
        record = kwargs[:session]
        build(kwargs, SESSION_KEYS, "hosted agent session") { |request| request[:session] = session_record!(record) }
      end

      def build(kwargs, allowed, path)
        Contracts::RequestValidation.reject_unknown_keys!(kwargs.except(*allowed), path: path)
        request = shared(kwargs)
        yield request
        request
      end

      def shared(kwargs)
        purpose = kwargs[:purpose]
        Contracts::RequestValidation.ensure_machine_purpose!(purpose) if purpose
        {
          purpose: purpose,
          metadata: RecordingStudioAI::Metadata.sanitize!(kwargs.fetch(:metadata, {}), path: "metadata"),
          attribution: attribution(kwargs)
        }
      end

      def attribution(kwargs)
        Contracts::RequestValidation.attribution_from!(**kwargs.slice(*ATTRIBUTION))
      end

      def assign_resolution!(request, kwargs)
        profile = kwargs[:profile]
        Contracts::RequestValidation.ensure_profile!(profile) if profile
        request[:profile] = profile&.to_sym
        request[:model] = Contracts::RequestValidation.normalize_model_override!(kwargs[:model])
        request[:provider] = kwargs[:provider]&.to_sym
        return if request[:profile] || request[:model]

        request[:profile] = RecordingStudioAI.configuration.default_profile
      end

      def session_record!(session)
        return session if session.is_a?(Session) && !session.provider_session_id.empty?

        invalid!("session must be a RecordingStudioAI::Agents::Session")
      end

      def required_text(value, name)
        return value if value.is_a?(String) && !value.strip.empty?

        invalid!("#{name} must be a non-empty String")
      end

      def optional_string(value, name)
        return if value.nil?
        return value if value.is_a?(String)

        invalid!("#{name} must be a String")
      end

      def required_key(value)
        return value if value.is_a?(String) && !value.strip.empty? && value.length <= 255

        invalid!("idempotency_key must be a non-empty String")
      end

      def invalid!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
    end
  end
end
