# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRegisteredProvidersScreen < RecordingStudioAdmin::Screen
    key "registered_providers"
    icon :server
    title "Registered providers"
    subtitle "Who's wired up."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.provider_rows(context)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :key, title: "Provider", header_tooltip: "The provider's name."
      column :class_name, title: "Implementation", header_tooltip: "The code that talks to it."
      column :configured,
             title: "Configured",
             header_tooltip: "Whether keys are set so it can run.",
             value: ->(row, _context) { row.configured ? "Yes" : "No" },
             display: :badge,
             display_options: lambda { |_row, _context, value|
               { text: value, style: value == "Yes" ? :success : :warning, size: :sm }
             }
      column :calls_series,
             title: "Calls",
             header_tooltip: "Daily call volume in the last 30 days. Open it to see the matching AI calls.",
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
      column :models_count,
             title: "Models",
             header_tooltip: "How many models this provider has. Open it to see them.",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 row.models_count.to_s,
                 AdminScreens::RecordingStudioAIWidgets.registered_models_path(context, provider: row.key),
                 data: { turbo_frame: "_top" },
                 aria: { label: "Registered models for #{row.key}" }
               )
             }
    end
  end
end
