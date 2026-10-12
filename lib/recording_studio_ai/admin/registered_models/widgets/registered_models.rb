# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredModelsWidget = RecordingStudioAdmin::Widget.new(
    "widgets.recording_studio_ai.registered_models"
  ) do
    type :list
    title { Copy.t("admin.widgets.registered_models.title", default: "Registered models") }
    subtitle { Copy.t("admin.widgets.registered_models.subtitle", default: "Top 5 models by call volume in the last 30 days.") }
    description { Copy.t("admin.widgets.registered_models.description", default: "Open the models screen to inspect every registered model definition.") }
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
      end.presence || [{ text: Copy.t("admin.widgets.registered_models.empty", default: "No registered models.") }]
    end
    link_to { |context| context.admin_screen_path("registered_models") }
  end
end
