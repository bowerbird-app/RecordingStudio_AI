# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredProvidersWidget = RecordingStudioAdmin::Widget.new(
    "widgets.recording_studio_ai.registered_providers"
  ) do
    type :list
    title { Copy.t("admin.widgets.registered_providers.title", default: "Registered providers") }
    subtitle { Copy.t("admin.widgets.registered_providers.subtitle", default: "Top 5 providers by call volume in the last 30 days.") }
    description { Copy.t("admin.widgets.registered_providers.description", default: "Open the providers screen to inspect every registered provider.") }
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_provider_call_rows(context, limit: 5)
      rows.map do |key, calls|
        {
          icon: :server,
          text: key,
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "#{context.admin_screen_path('ai_calls')}?#{{
            provider: key,
            date_range_preset: :last_30_days
          }.to_query}"
        }
      end.presence || [{ text: Copy.t("admin.widgets.registered_providers.empty", default: "No registered providers.") }]
    end
    link_to { |context| context.admin_screen_path("registered_providers") }
  end
end
