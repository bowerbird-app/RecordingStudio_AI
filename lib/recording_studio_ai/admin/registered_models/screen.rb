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

      column :provider, title: "Provider", header_tooltip: "Who this model belongs to."
      column :model, title: "Model", header_tooltip: "The model name used in calls."
      column :temperature, title: "Temperature", header_tooltip: "How wild the answers can get."
      column :verbosity, title: "Verbosity", header_tooltip: "How talkative the answers are."
      column :reasoning_effort, title: "Reasoning", header_tooltip: "How hard it thinks before answering."
      column :streaming,
             title: "Streaming",
             header_tooltip: "Whether answers can arrive live.",
             value: ->(row, _context) { row.streaming ? "Yes" : "No" }
      column :structured_output,
             title: "Structured",
             header_tooltip: "Whether answers can come back as tidy data.",
             value: ->(row, _context) { row.structured_output ? "Yes" : "No" }
      column :batch,
             title: "Batch",
             header_tooltip: "Whether it can run a pile of calls overnight.",
             value: ->(row, _context) { row.batch ? "Yes" : "No" }
      column :tools, title: "Tools", header_tooltip: "Built-in tools this model can use."
      column :input_modalities, title: "Input", header_tooltip: "What you can send it."
      column :output_modalities, title: "Output", header_tooltip: "What it can send back."
      column :calls_series,
             title: "Calls",
             header_tooltip: "Daily call volume in the last 30 days. Open it to see the matching AI calls.",
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
