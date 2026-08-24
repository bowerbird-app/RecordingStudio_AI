# frozen_string_literal: true

module RecordingStudioAI
  module Authorization
    ACTIONS = {
      execute: "recording_studio_ai.execute",
      use_provider_native_tool: "recording_studio_ai.use_provider_native_tool",
      use_custom_tool: "recording_studio_ai.use_custom_tool",
      confirm_custom_tool: "recording_studio_ai.confirm_custom_tool",
      submit_batch: "recording_studio_ai.submit_batch",
      cancel_batch: "recording_studio_ai.cancel_batch",
      view_execution: "recording_studio_ai.view_execution",
      view_sensitive_execution: "recording_studio_ai.view_sensitive_execution",
      view_retained_response: "recording_studio_ai.view_retained_response"
    }.freeze

    module_function

    def authorize!(action_key, attribution:, context: {})
      action_name = ACTIONS.fetch(action_key)
      handler = RecordingStudioAI.configuration.authorization_handler

      allowed = handler.call(
        action: action_name,
        attribution: attribution,
        context: RecordingStudioAI::Contracts::Containment.ensure_serializable!(context, path: "authorization.context")
      )

      return true if allowed.equal?(true)

      raise RecordingStudioAI::Errors::ContractValidationError.new(
        "Not authorized for action #{action_name}",
        code: "authorization"
      )
    end
  end
end
