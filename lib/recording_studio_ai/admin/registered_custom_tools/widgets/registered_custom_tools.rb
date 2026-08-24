# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRegisteredCustomToolsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.registered_custom_tools") do
    type :list
    title "Custom tools"
    subtitle "Most-used tools by calls in the last 30 days."
    description "Open a tool to inspect its definition and recent executions."
    list_options { { divider: true } }
    items do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.tool_scope(context)
                                                   .where(created_at: 30.days.ago..Time.current)
                                                   .group(:tool_key)
                                                   .count
                                                   .sort_by { |_tool_key, count| -count }
                                                   .first(3)
      rows.map do |tool_key, calls|
        definition = RecordingStudioAI.tools.fetch(tool_key)
        next unless definition

        {
          icon: :wrench_screwdriver,
          text: definition.name,
          trailing: "#{AdminScreens::RecordingStudioAIWidgets.number(calls)} calls",
          href: "/recording_studio_ai/admin/custom_tools/#{definition.key}/versions/#{definition.version}"
        }
      end.compact.presence || [{ text: "No custom tool calls in the last 30 days." }]
    end
    link_to { |context| context.admin_screen_path("registered_custom_tools") }
  end
end
