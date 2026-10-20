# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredCustomToolsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.registered_custom_tools") do
    type :list
    title { Copy.t("admin.widgets.registered_custom_tools.title") }
    subtitle { Copy.t("admin.widgets.registered_custom_tools.subtitle") }
    description { Copy.t("admin.widgets.registered_custom_tools.description") }
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.site_tool_scope(context)
                                                   .where(created_at: 30.days.ago..Time.current)
                                                   .group(:tool_key)
                                                   .count
                                                   .sort_by { |_tool_key, count| -count }
                                                   .first(3)
      rows.map do |tool_key, calls|
        definition = RecordingStudioAI.tools.fetch(tool_key)
        next unless definition

        query = { tool_key: definition.key }.to_query
        {
          icon: :wrench_screwdriver,
          text: definition.name,
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "#{context.admin_screen_path('tool_calls')}?#{query}"
        }
      end.compact.presence || [{ text: Copy.t("admin.widgets.registered_custom_tools.empty") }]
    end
    link_to { |context| context.admin_screen_path("registered_custom_tools") }
  end
end
