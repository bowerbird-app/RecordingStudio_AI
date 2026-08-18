# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAILatencyByPromptScreen < RecordingStudioAdmin::Screen
    key "latency_by_prompt"
    icon :chart_bar
    title "Latency by prompt"
    subtitle "Compare prompt response speed using P90 latency."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.latency_rows(context, dimension: :prompt)
    end

    filter_presentation :modal, inline_count: 1
    filter :date_range, field: :created_at, default: :last_30_days

    chart do
      title "Prompt P90 latency"
      subtitle "Latency at or below which 90% of calls completed."
      type :bar
      series { |context| [{ name: "P90 latency (ms)", data: context.query_result.relation.map(&:p90_latency_ms) }] }
      options do |context|
        {
          height: 300,
          plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
          xaxis: { categories: context.query_result.relation.map(&:name), min: 0 },
          dataLabels: { enabled: false }
        }
      end
    end

    table do
      hide_columns_button
      column :name, title: "Prompt"
      column :calls, title: "Calls"
      column :p50_latency_ms, title: "Median (ms)",
                              header_tooltip: "Median latency: half of calls completed within this time."
      column :p90_latency_ms, title: "P90 (ms)", header_tooltip: "90% of calls completed within this time."
      column :average_latency_ms, title: "Average (ms)"
      column :max_latency_ms, title: "Max (ms)"
    end
  end
end
