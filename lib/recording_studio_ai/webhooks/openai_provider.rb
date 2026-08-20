# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # Optional RecordingStudioWebhooks provider recipe for OpenAI. Hosts call
    # register! only when recording_studio_webhooks is installed. Secrets stay
    # in config/ENV — never endpoint metadata.
    module OpenaiProvider
      PROVIDER_NAME = "openai"

      module_function

      def signature_verifier
        lambda do |context|
          secret = RecordingStudioAI.configuration.openai_webhook_secret
          return false if secret.nil? || secret.to_s.empty?

          client = openai_client(secret)
          client.webhooks.verify_signature(context.raw_payload, context.headers, secret)
          true
        rescue StandardError
          false
        end
      end

      def event_type_extractor
        lambda do |payload|
          hash = OpenaiBatchPayload.normalize_hash(payload)
          next nil if hash.nil?

          hash[:type] || hash["type"]
        end
      end

      def event_id_extractor
        ->(payload) { OpenaiBatchPayload.event_id(payload) }
      end

      def register!(name: PROVIDER_NAME, **options)
        require_webhooks_gem!

        RecordingStudioWebhooks.register_provider(
          name,
          signature_verifier: options.fetch(:signature_verifier, signature_verifier),
          event_type_extractor: options.fetch(:event_type_extractor, event_type_extractor),
          event_id_extractor: options.fetch(:event_id_extractor, event_id_extractor),
          **options.except(:signature_verifier, :event_type_extractor, :event_id_extractor)
        )
      end

      def openai_client(secret)
        configured = RecordingStudioAI.configuration.openai_client
        return configured if configured.respond_to?(:webhooks)

        ::OpenAI::Client.new(
          api_key: RecordingStudioAI.configuration.openai_api_key,
          webhook_secret: secret
        )
      end
      module_function :openai_client

      def require_webhooks_gem!
        return if defined?(RecordingStudioWebhooks)

        raise LoadError,
              "recording_studio_webhooks is required to register the OpenAI webhook provider"
      end
      module_function :require_webhooks_gem!
    end
  end
end
