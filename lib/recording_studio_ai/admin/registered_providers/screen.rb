# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRegisteredProvidersScreen < RecordingStudioAdmin::Screen
    key "registered_providers"
    icon :server
    title "Registered providers"
    subtitle "Providers currently registered on RecordingStudioAI.configuration."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.provider_rows(context)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :key, title: "Provider"
      column :class_name, title: "Implementation"
      column :configured,
             title: "Configured",
             value: ->(row, _context) { row.configured ? "Yes" : "No" },
             display: :badge,
             display_options: lambda { |_row, _context, value|
               { text: value, style: value == "Yes" ? :success : :warning, size: :sm }
             }
      column :calls_series,
             title: "Calls",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 "#{context.admin_screen_path('ai_calls')}?#{{
                   provider: row.key,
                   date_range_preset: :last_30_days
                 }.to_query}",
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.key} in the last 30 days" }
               )
             }
      column :models_count, title: "Models"
    end
  end
end
