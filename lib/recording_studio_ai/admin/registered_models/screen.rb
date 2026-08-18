# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRegisteredModelsScreen < RecordingStudioAdmin::Screen
    key "registered_models"
    icon :cube
    title "Registered models"
    subtitle "Model definitions registered through RecordingStudioAI.models."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.model_rows(context)
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :provider, title: "Provider"
      column :model, title: "Model"
      column :temperature, title: "Temperature"
      column :verbosity, title: "Verbosity"
      column :reasoning_effort, title: "Reasoning"
      column :streaming,
             title: "Streaming",
             value: ->(row, _context) { row.streaming ? "Yes" : "No" }
      column :structured_output,
             title: "Structured",
             value: ->(row, _context) { row.structured_output ? "Yes" : "No" }
      column :batch,
             title: "Batch",
             value: ->(row, _context) { row.batch ? "Yes" : "No" }
      column :tools, title: "Tools"
      column :input_modalities, title: "Input"
      column :output_modalities, title: "Output"
      column :calls_series,
             title: "Calls",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 "#{context.admin_screen_path('ai_calls')}?#{{
                   provider: row.provider,
                   model: row.model,
                   date_range_preset: :last_30_days
                 }.to_query}",
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.provider}/#{row.model} in the last 30 days" }
               )
             }
    end
  end
end
