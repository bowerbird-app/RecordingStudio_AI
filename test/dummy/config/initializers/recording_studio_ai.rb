# frozen_string_literal: true

RecordingStudioAI.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY", nil)
  config.gemini_api_key = ENV.fetch("GEMINI_API_KEY", nil)

  config.default_profile = :medium
  config.authorization_handler = ->(action:, attribution:, context:) { true }
  config.attribution_validator = lambda do |root_recording:, context_recording:|
    unless root_recording.is_a?(RecordingStudio::Recording) &&
           root_recording.parent_recording_id.nil? &&
           root_recording.root_recording_id == root_recording.id
      raise ArgumentError, "root_recording must be a Recording Studio root"
    end
    if context_recording && context_recording.root_recording_id != root_recording.id
      raise ArgumentError, "context_recording must belong to root_recording"
    end
  end
  config.retain_responses = false
  config.response_retention_period = 7.days
  config.maximum_retained_response_size = 1.megabyte
  config.admin_actor_resolver = ->(controller:) { Current.actor }
  config.admin_visible_roots_resolver = lambda do |actor:, controller:|
    RecordingStudio::Recording.where(parent_recording_id: nil).pluck(:id)
  end
  config.admin_layout = "flat_pack_sidebar"
  config.maximum_attempts = 3
  config.maximum_retries_per_candidate = 1
  config.maximum_provider_fallbacks = 1
  config.maximum_custom_tool_rounds = 5
  config.request_timeout = 120
  config.stream_idle_timeout = 30
end
