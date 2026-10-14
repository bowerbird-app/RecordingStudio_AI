# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAISection < RecordingStudioAdmin::Section
    key "recording_studio_ai"
    icon :cpu_chip
    title { Copy.t("admin.section.title") }
    subtitle { Copy.t("admin.section.subtitle") }

    link :calls,
         text: ->(_context) { Copy.t("admin.section.links.calls") },
         url: ->(context) { context.admin_screen_path("ai_calls") },
         style: :secondary

    link :tool_calls,
         text: ->(_context) { Copy.t("admin.section.links.tool_calls") },
         url: ->(context) { context.admin_screen_path("tool_calls") },
         style: :secondary

    link :attempts,
         text: ->(_context) { Copy.t("admin.section.links.attempts") },
         url: ->(context) { context.admin_screen_path("attempts") },
         style: :secondary

    link :provider_batches,
         text: ->(_context) { Copy.t("admin.section.links.provider_batches") },
         url: ->(context) { context.admin_screen_path("provider_batches") },
         style: :secondary

    link :custom_tools,
         text: ->(_context) { Copy.t("admin.section.links.custom_tools") },
         url: ->(context) { context.admin_screen_path("registered_custom_tools") },
         style: :secondary

    link :registered_prompts,
         text: ->(_context) { Copy.t("admin.section.links.registered_prompts") },
         url: ->(context) { context.admin_screen_path("registered_prompts") },
         style: :secondary

    link :estimated_spend,
         text: ->(_context) { Copy.t("admin.section.links.estimated_spend") },
         url: ->(context) { context.admin_screen_path("estimated_spend") },
         style: :secondary

    link :calls_by_provider_model,
         text: ->(_context) { Copy.t("admin.section.links.calls_by_provider_model") },
         url: ->(context) { context.admin_screen_path("calls_by_provider_model") },
         style: :secondary

    link :latency_by_model,
         text: ->(_context) { Copy.t("admin.section.links.latency_by_model") },
         url: ->(context) { context.admin_screen_path("latency_by_model") },
         style: :secondary

    link :latency_by_prompt,
         text: ->(_context) { Copy.t("admin.section.links.latency_by_prompt") },
         url: ->(context) { context.admin_screen_path("latency_by_prompt") },
         style: :secondary

    link :responses,
         text: ->(_context) { Copy.t("admin.section.links.responses") },
         url: ->(context) { context.admin_screen_path("recording_studio_ai_responses") },
         style: :secondary

    link :registered_providers,
         text: ->(_context) { Copy.t("admin.section.links.registered_providers") },
         url: ->(context) { context.admin_screen_path("registered_providers") },
         style: :secondary

    link :registered_models,
         text: ->(_context) { Copy.t("admin.section.links.registered_models") },
         url: ->(context) { context.admin_screen_path("registered_models") },
         style: :secondary

    link :profiles,
         text: ->(_context) { Copy.t("admin.section.links.profiles") },
         url: ->(context) { context.admin_screen_path("profiles") },
         style: :secondary

    widget "widgets.recording_studio_ai.ai_calls_windows"
    widget "widgets.recording_studio_ai.tool_calls"
    widget "widgets.recording_studio_ai.registered_custom_tools"
    widget "widgets.recording_studio_ai.registered_prompts"
    widget "widgets.recording_studio_ai.retry_rate_by_model"
    widget "widgets.recording_studio_ai.errors_failed_calls"
    widget "widgets.recording_studio_ai.calls_by_provider_model"
    widget "widgets.recording_studio_ai.estimated_spend"
    widget "widgets.recording_studio_ai.prompt_p90_latency"
    widget "widgets.recording_studio_ai.slow_calls"
    widget "widgets.recording_studio_ai.registered_providers"
    widget "widgets.recording_studio_ai.registered_models"
  end
end
