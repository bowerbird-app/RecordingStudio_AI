# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRegisteredCustomToolsScreen < RecordingStudioAdmin::Screen
    key "registered_custom_tools"
    icon :wrench_screwdriver
    title "Registered custom tools"
    subtitle "Definitions, safety classifications, and execution reliability across visible roots."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.custom_tool_rows(context)
    end

    filter_presentation :modal, inline_count: 1
    filter :date_range, field: :created_at, default: :last_4_weeks

    table do
      title ""
      hide_columns_button
      hide_count

      column :name,
             title: "Tool",
             value: lambda { |row, _context|
               AdminScreens::RecordingStudioAIWidgets.custom_tool_definition_modal(row)
             }
      column :description, title: "Description"
      column :cost_class, title: "Cost class"
      column :safety, title: "Safety"
      column :calls_series,
             title: "Calls",
             value: lambda { |row, context|
               date_range_query = AdminScreens::RecordingStudioAIWidgets.date_range_query(context)
               url = "/admin/screens/ai_calls?#{{ **date_range_query, custom_tool_key: row.key }.to_query}"
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 url,
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.name} in the selected date range" }
               )
             }
      column :success_rate, title: "Success rate", value: ->(row, _context) { "#{row.success_rate}%" }
      column :error_rate, title: "Error rate", value: ->(row, _context) { "#{row.error_rate}%" }
      column :average_duration, title: "Average duration"
    end
  end
end
