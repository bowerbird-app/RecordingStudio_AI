# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAISection < RecordingStudioAdmin::Section
    key "recording_studio_ai"
    icon :cpu_chip
    title "Recording Studio AI"
    subtitle "Runs, custom tools, provider batches, and retained responses"

    link :calls,
         text: "AI Calls",
         url: ->(context) { context.admin_screen_path("ai_calls") },
         style: :secondary

    link :tool_calls,
         text: "Custom Tool Calls",
         url: ->(context) { context.admin_screen_path("tool_calls") },
         style: :secondary

    link :attempts,
         text: "Attempts",
         url: ->(context) { context.admin_screen_path("attempts") },
         style: :secondary

    link :custom_tools,
         text: "Registered Tools",
         url: ->(context) { context.admin_screen_path("registered_custom_tools") },
         style: :secondary

    link :registered_prompts,
         text: "Registered Prompts",
         url: ->(context) { context.admin_screen_path("registered_prompts") },
         style: :secondary

    link :estimated_spend,
         text: "Estimated token usage",
         url: ->(context) { context.admin_screen_path("estimated_spend") },
         style: :secondary

    link :latency_by_model,
         text: "Latency by Model",
         url: ->(context) { context.admin_screen_path("latency_by_model") },
         style: :secondary

    link :latency_by_prompt,
         text: "Latency by Prompt",
         url: ->(context) { context.admin_screen_path("latency_by_prompt") },
         style: :secondary

    link :responses,
         text: "AI Responses",
         url: ->(context) { context.admin_screen_path("recording_studio_ai_responses") },
         style: :secondary

    link :registered_providers,
         text: "Registered Providers",
         url: ->(context) { context.admin_screen_path("registered_providers") },
         style: :secondary

    link :registered_models,
         text: "Registered Models",
         url: ->(context) { context.admin_screen_path("registered_models") },
         style: :secondary

    widget "widgets.recording_studio_ai.ai_calls_windows"
    widget "widgets.recording_studio_ai.tool_calls"
    widget "widgets.recording_studio_ai.registered_custom_tools"
    widget "widgets.recording_studio_ai.registered_prompts"
    widget "widgets.recording_studio_ai.retry_rate_by_model"
    widget "widgets.recording_studio_ai.errors_failed_calls"
    widget "widgets.recording_studio_ai.calls_by_provider_model"
    widget "widgets.recording_studio_ai.estimated_spend"
    widget "widgets.recording_studio_ai.slow_calls"
    widget "widgets.recording_studio_ai.prompt_p90_latency"
    widget "widgets.recording_studio_ai.registered_providers"
    widget "widgets.recording_studio_ai.registered_models"
  end
end
