# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRegisteredPromptsScreen < RecordingStudioAdmin::Screen
    key "registered_prompts"
    icon :document_text
    title "Registered prompts"
    subtitle "Prompt definitions and call volume across visible roots."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.prompt_rows(context)
    end

    filter_presentation :modal, inline_count: 1
    filter :date_range, field: :created_at, default: :last_4_weeks

    chart do
      title "Prompt call volume"
      subtitle "All registered prompts by call volume in the selected date range."
      type :bar
      series do |context|
        rows = context.query_result.relation
        [{ name: "Calls", data: rows.map(&:calls) }]
      end
      options do |context|
        rows = context.query_result.relation
        {
          height: [300, (rows.length * 40) + 80].max,
          plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
          xaxis: {
            categories: rows.map { |row| AdminScreens::RecordingStudioAIWidgets.prompt_chart_label(row) },
            min: 0
          },
          dataLabels: { enabled: false }
        }
      end
    end

    table do
      title ""
      hide_columns_button
      hide_count

      column :name,
             title: "Prompt",
             value: lambda { |row, _context|
               AdminScreens::RecordingStudioAIWidgets.prompt_definition_modal(row)
             }
      column :namespace, title: "Namespace"
      column :key, title: "Key"
      column :description, title: "Description"
      column :calls_series,
             title: "Calls",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 AdminScreens::RecordingStudioAIWidgets.prompt_calls_path(context, row),
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.name} in the selected date range" }
               )
             }
      column :success_rate, title: "Success rate", value: ->(row, _context) { "#{row.success_rate}%" }
      column :error_rate, title: "Error rate", value: ->(row, _context) { "#{row.error_rate}%" }
      column :average_duration, title: "Average duration"
      column :average_input_tokens, title: "Avg input"
      column :average_output_tokens, title: "Avg output"
    end
  end
end
