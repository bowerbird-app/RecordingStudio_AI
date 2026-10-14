# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredModelsWidget = RecordingStudioAdmin::Widget.new(
    "widgets.recording_studio_ai.registered_models"
  ) do
    type :list
    title { Copy.t("admin.widgets.registered_models.title") }
    subtitle { Copy.t("admin.widgets.registered_models.subtitle") }
    description { Copy.t("admin.widgets.registered_models.description") }
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_call_rows(context, limit: 5)
      rows.map do |provider, model, display_name, calls|
        {
          icon: :cube,
          text: "#{display_name} (#{provider})",
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "#{context.admin_screen_path('ai_calls')}?#{{
            provider: provider,
            model: model,
            date_range_preset: :last_30_days
          }.to_query}"
        }
      end.presence || [{ text: Copy.t("admin.widgets.registered_models.empty") }]
    end
    link_to { |context| context.admin_screen_path("registered_models") }
  end
end
