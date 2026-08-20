# frozen_string_literal: true

module RecordingStudioAI
  module Webhooks
    # Resolves the AI attribution root from a webhooks endpoint or recording.
    # Hosts attach RecordingStudioWebhooks::Endpoint under a root; batch rows
    # are scoped by that root's id.
    module RootRecording
      module_function

      def from(endpoint_or_recording)
        recording = recording_for(endpoint_or_recording)
        validation_error!("webhook root recording is required") if recording.nil?

        root = resolve_root(recording)
        validation_error!("webhook root recording is required") if root.nil?
        root
      end

      def recording_for(endpoint_or_recording)
        return nil if endpoint_or_recording.nil?
        if endpoint_or_recording.respond_to?(:recording_studio_recording)
          return endpoint_or_recording.recording_studio_recording
        end

        endpoint_or_recording
      end
      module_function :recording_for

      def resolve_root(recording)
        if recording.respond_to?(:root_recording_or_self)
          recording.root_recording_or_self
        elsif recording.respond_to?(:root_recording) && !recording.root_recording.nil?
          recording.root_recording
        else
          recording
        end
      end
      module_function :resolve_root

      def validation_error!(message)
        raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: "invalid_request")
      end
      module_function :validation_error!
    end
  end
end
