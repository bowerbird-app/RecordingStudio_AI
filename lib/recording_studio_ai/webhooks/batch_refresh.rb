# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # Wakes the existing poll path after a provider batch webhook. Does not trust
    # webhook payload status or results — always runs refresh_batch.
    module BatchRefresh
      module_function

      def call(provider_batch_id:, root_recording:, async: false, **attribution)
        batch = BatchLookup.find!(
          provider_batch_id: provider_batch_id,
          root_recording: root_recording
        )
        arguments = refresh_arguments(
          batch: batch,
          root_recording: root_recording,
          **attribution
        )

        if async
          RecordingStudioAI.refresh_batch_async(**arguments)
        else
          RecordingStudioAI.refresh_batch(**arguments)
        end
      end

      def refresh_arguments(batch:, root_recording:, initiator: nil, **attribution)
        {
          batch_id: batch.id,
          root_recording: root_recording,
          initiator: resolve_initiator!(
            initiator: initiator,
            root_recording: root_recording,
            provider_batch_id: batch.provider_batch_id,
            batch_id: batch.id
          ),
          initiator_kind: attribution.fetch(:initiator_kind, :system),
          execution_source: attribution.fetch(:execution_source, :webhook),
          context_recording: attribution[:context_recording],
          executor: attribution[:executor],
          impersonator: attribution[:impersonator],
          request_id: attribution[:request_id],
          job_id: attribution[:job_id]
        }
      end
      module_function :refresh_arguments

      def resolve_initiator!(initiator:, root_recording:, provider_batch_id:, batch_id:)
        return initiator unless initiator.nil?

        resolved = configured_initiator(
          root_recording: root_recording,
          provider_batch_id: provider_batch_id,
          batch_id: batch_id
        )
        return resolved unless resolved.nil?

        raise RecordingStudioAI::Errors::ContractValidationError.new(
          "config.webhook_batch_initiator must return an initiator",
          code: "configuration"
        )
      end
      module_function :resolve_initiator!

      def configured_initiator(**)
        resolver = RecordingStudioAI.configuration.webhook_batch_initiator
        unless resolver.respond_to?(:call)
          raise RecordingStudioAI::Errors::ContractValidationError.new(
            "initiator is required (or set config.webhook_batch_initiator)",
            code: "invalid_request"
          )
        end

        resolver.call(**)
      end
      module_function :configured_initiator
    end
  end
end
