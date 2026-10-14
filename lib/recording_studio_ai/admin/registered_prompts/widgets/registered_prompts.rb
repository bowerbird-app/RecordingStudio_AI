# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredPromptsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.registered_prompts") do
    type :list
    title { Copy.t("admin.widgets.registered_prompts.title") }
    subtitle { Copy.t("admin.widgets.registered_prompts.subtitle") }
    description { Copy.t("admin.widgets.registered_prompts.description") }
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_prompt_call_rows(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        range: 30.days.ago..Time.current,
        limit: 5
      )
      rows.map do |name, prompt_key, calls|
        {
          icon: :document_text,
          text: name,
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "#{context.admin_screen_path('ai_calls')}?#{{
            prompt: prompt_key
          }.compact.to_query}"
        }
      end.presence || [{ text: Copy.t("admin.widgets.registered_prompts.empty") }]
    end
    link_to { |context| context.admin_screen_path("registered_prompts") }
  end
end
