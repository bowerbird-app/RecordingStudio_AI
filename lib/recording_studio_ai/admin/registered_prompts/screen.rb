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

    summary do
      label "Calls"
      value do |context|
        Array(context.query_result&.relation).sum { |row| row.respond_to?(:calls) ? row.calls.to_i : 0 }
      end
      previous_value do |context|
        widgets = AdminScreens::RecordingStudioAIWidgets
        previous = widgets.previous_period_date_range(widgets.registered_prompts_date_range_value(context))
        widgets.prompt_call_count(context, date_range: previous)
      end
    end

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
      show_columns_button
      hide_count

      column :name,
             title: "Prompt",
             header_tooltip: "Open the prompt's definition.",
             value: lambda { |row, _context|
               AdminScreens::RecordingStudioAIWidgets.prompt_definition_modal(row)
             }
      column :key, title: "Key", header_tooltip: "Stable name used in code."
      column :description, title: "Description", header_tooltip: "What this prompt is for."
      column :calls_series,
             title: "Calls",
             header_tooltip: "Daily call volume in this date range. Open it to see the matching AI calls.",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 AdminScreens::RecordingStudioAIWidgets.prompt_calls_path(context, row),
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: "AI calls for #{row.name} in the selected date range" }
               )
             }
      column :success_rate, title: "Success rate",
                            header_tooltip: "Share of runs that worked.",
                            value: ->(row, _context) { "#{row.success_rate}%" }
      column :error_rate, title: "Error rate",
                          header_tooltip: "Share of runs that failed.",
                          value: ->(row, _context) { "#{row.error_rate}%" }
      column :average_duration, title: "Average duration", header_tooltip: "Typical wait for this prompt."
      column :average_input_tokens, title: "Avg input", header_tooltip: "Typical size of what we send."
      column :average_output_tokens, title: "Avg output", header_tooltip: "Typical size of what comes back."

      default_columns :name, :description, :calls_series, :success_rate, :error_rate, :average_duration,
                      :average_input_tokens, :average_output_tokens
    end
  end
end
