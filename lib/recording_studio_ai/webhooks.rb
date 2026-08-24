# frozen_string_literal: true

require "recording_studio_ai/webhooks/root_recording"
require "recording_studio_ai/webhooks/batch_lookup"
require "recording_studio_ai/webhooks/batch_refresh"
require "recording_studio_ai/webhooks/openai_batch_payload"
require "recording_studio_ai/webhooks/openai_provider"
require "recording_studio_ai/webhooks/openai_batch_completion"

module RecordingStudioAI
  # Preparation for inbound provider batch webhooks via recording_studio_webhooks.
  # This gem does not mount intake or depend on the webhooks engine. Hosts install
  # recording_studio_webhooks, register the optional OpenAI recipes, and keep
  # BatchSynchronizationJob as a poll fallback.
  module Webhooks
    module_function

    def require_webhooks_gem!(message)
      return if defined?(RecordingStudioWebhooks)

      raise LoadError, message
    end
  end
end
