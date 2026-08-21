# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # Optional RecordingStudioWebhooks action recipe. Wakes refresh_batch for
    # OpenAI batch.* events. Keep BatchSynchronizationJob as a missed-delivery
    # fallback — this does not replace polling.
    module OpenaiBatchCompletion
      ACTION_NAME = "recording_studio_ai.openai_batch_terminal"
      PROVIDER_NAME = OpenaiProvider::PROVIDER_NAME
      EVENT = "batch.*"

      module_function

      def call(context)
        payload = context.respond_to?(:payload) ? context.payload : context
        provider_batch_id = OpenaiBatchPayload.provider_batch_id!(payload)
        root_recording = RootRecording.from(context.endpoint)
        request_id = OpenaiBatchPayload.event_id(payload)

        RecordingStudioAI.refresh_batch_from_webhook(
          provider_batch_id: provider_batch_id,
          root_recording: root_recording,
          request_id: request_id
        )
      end

      def register!(name: ACTION_NAME, provider: PROVIDER_NAME, event: EVENT, **)
        require_webhooks_gem!

        RecordingStudioWebhooks.register_action(
          name,
          method(:call),
          provider: provider,
          event: event,
          **
        )
      end

      def require_webhooks_gem!
        Webhooks.require_webhooks_gem!(
          "recording_studio_webhooks is required to register the OpenAI batch completion action"
        )
      end
      module_function :require_webhooks_gem!
    end
  end
end
