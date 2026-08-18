# frozen_string_literal: true

module AdminScreens
  DEFINITION_FILES = %w[
    recording_studio_ai_widgets
    ai_calls/widgets/ai_calls_windows
    ai_calls/widgets/retry_rate_by_model
    ai_calls/widgets/errors_failed_calls
    ai_calls/widgets/calls_by_provider_model
    tool_calls/widgets/tool_calls
    registered_custom_tools/widgets/registered_custom_tools
    registered_prompts/widgets/registered_prompts
    registered_providers/widgets/registered_providers
    registered_models/widgets/registered_models
    estimated_spend/widgets/estimated_spend
    latency_by_model/widgets/slow_calls
    latency_by_prompt/widgets/prompt_p90_latency
    recording_studio_ai_overview/screen
    recording_studio_ai_responses/screen
    ai_calls/screen
    attempts/screen
    tool_calls/screen
    registered_custom_tools/screen
    registered_prompts/screen
    registered_providers/screen
    registered_models/screen
    estimated_spend/screen
    latency_by_model/screen
    latency_by_prompt/screen
    section
  ].freeze

  DEFINITION_FILES.each do |path|
    require_relative path
  end

  REGISTERABLE_WIDGETS = [
    RecordingStudioAIAICallsWindowsWidget,
    RecordingStudioAIToolCallsWidget,
    RecordingStudioAIRegisteredCustomToolsWidget,
    RecordingStudioAIRegisteredPromptsWidget,
    RecordingStudioAIRetryRateByModelWidget,
    RecordingStudioAIErrorsFailedCallsWidget,
    RecordingStudioAIEstimatedSpendWidget,
    RecordingStudioAICallsByProviderModelWidget,
    RecordingStudioAISlowCallsWidget,
    RecordingStudioAIPromptP90LatencyWidget,
    RecordingStudioAIRegisteredProvidersWidget,
    RecordingStudioAIRegisteredModelsWidget
  ].freeze

  def self.register!
    return unless defined?(RecordingStudioAdmin)

    REGISTERABLE_WIDGETS.each { |widget| RecordingStudioAdmin.register_widget(widget) }
    RecordingStudioAdmin.register_screen(RecordingStudioAIOverviewScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAICallsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIAttemptsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIToolCallsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIRegisteredCustomToolsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIRegisteredPromptsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIRegisteredProvidersScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIRegisteredModelsScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIEstimatedSpendScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAILatencyByModelScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAILatencyByPromptScreen)
    RecordingStudioAdmin.register_screen(RecordingStudioAIResponsesScreen)
    RecordingStudioAdmin.register_section(RecordingStudioAISection)
  end

  # Backward-compatible entry point used in earlier dummy-app workflow.
  def self.load!
    register!
  end
end
