# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAILatencyByPromptScreen < RecordingStudioAdmin::Screen
    key "latency_by_prompt"
    icon :chart_bar
    title { Copy.t("admin.screens.latency_by_prompt.title", default: "Latency by prompt") }
    subtitle { Copy.t("admin.screens.latency_by_prompt.subtitle", default: "Compare prompt response speed using P90 latency.") }

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.latency_rows(context, dimension: :prompt)
    end

    filter_presentation :modal, inline_count: 1
    filter :date_range, field: :created_at, default: :last_4_weeks

    summary do
      label { Copy.t("common.p90_ms", default: "P90 (ms)") }
      change_good_when :down
      value do |context|
        AdminScreens::RecordingStudioAIWidgets.latency_summary_p90(context, dimension: :prompt)
      end
      previous_value do |context|
        AdminScreens::RecordingStudioAIWidgets.latency_summary_p90(context, dimension: :prompt, previous: true)
      end
    end

    chart do
      title { Copy.t("admin.screens.latency_by_prompt.chart_title", default: "Prompt P90 latency") }
      subtitle { Copy.t("admin.screens.latency_by_prompt.chart_subtitle", default: "Latency at or below which 90% of calls completed.") }
      type :bar
      series { |context| [{ name: Copy.t("common.p90_latency_ms", default: "P90 latency (ms)"), data: context.query_result.relation.map(&:p90_latency_ms) }] }
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
      column :name, title: "Prompt", header_tooltip: "The prompt these calls used."
      column :calls_series,
             title: "Calls",
             sortable: false,
             header_tooltip: "Daily call volume in this date range. Open it to see the matching AI calls.",
             value: lambda { |row, context|
               ActionController::Base.helpers.link_to(
                 AdminScreens::RecordingStudioAIWidgets.mini_chart(row.calls_series),
                 AdminScreens::RecordingStudioAIWidgets.latency_prompt_calls_path(context, row),
                 class: "inline-block",
                 data: { turbo_frame: "_top" },
                 aria: { label: Copy.t("common.ai_calls_for_name_range", name: row.name, default: "AI calls for %{name} in the selected date range") }
               )
             }
      column :p50_latency_ms, title: "Median (ms)",
                              header_tooltip: "Half of calls finished faster than this."
      column :p90_latency_ms, title: "P90 (ms)",
                              header_tooltip: "Nine out of ten calls finished within this time."
      column :average_latency_ms, title: "Average (ms)",
                                  header_tooltip: "The blended wait if you mix every call together."
      column :max_latency_ms, title: "Max (ms)",
                              header_tooltip: "The slowest call in this date range."
    end
  end
end
