# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # Finds a local batch for a provider webhook wake-up. Scope is always the
    # Recording Studio root so provider batch ids cannot cross tenants.
    module BatchLookup
      module_function

      def find!(provider_batch_id:, root_recording:)
        provider_batch_id = normalize_provider_batch_id!(provider_batch_id)
        root_id = identifier(root_recording)
        validation_error!("root_recording is required") if root_id.nil?

        matches = scope(provider_batch_id, root_id).to_a
        ensure_single_match!(matches, provider_batch_id)
        matches.first
      end

      def scope(provider_batch_id, root_id)
        RecordingStudioAI::Batch.where(
          provider_batch_id: provider_batch_id,
          root_recording_id: root_id
        )
      end
      module_function :scope

      def ensure_single_match!(matches, provider_batch_id)
        if matches.empty?
          validation_error!(
            "batch was not found for provider_batch_id #{provider_batch_id} in the requested root"
          )
        end
        return if matches.length == 1

        validation_error!(
          "multiple batches match provider_batch_id #{provider_batch_id} in the requested root"
        )
      end
      module_function :ensure_single_match!

      def normalize_provider_batch_id!(value)
        id = value.to_s.strip
        validation_error!("provider_batch_id is required") if id.empty?

        id
      end
      module_function :normalize_provider_batch_id!

      def identifier(value)
        return nil if value.nil?
        return value.id if value.respond_to?(:id)

        value
      end
      module_function :identifier

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
      module_function :validation_error!
    end
  end
end
