# frozen_string_literal: true

module AdminScreens
  RecordingStudioAISlowCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.slow_calls") do
    type :chart
    title { Copy.t("admin.widgets.slow_calls.title") }
    subtitle { Copy.t("admin.widgets.slow_calls.subtitle") }
    description { Copy.t("admin.widgets.slow_calls.description") }
    metadata { { period_label: Copy.t("common.last_30_days") } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.site_runs_scope(context)
                                                   .where(created_at: 30.days.ago..Time.current)
                                                   .where.not(latency_ms: nil)
      p90_latency = AdminScreens::RecordingStudioAIWidgets.p90_latency(runs)
      "#{AdminScreens::RecordingStudioAIWidgets.number(p90_latency)} ms"
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.site_runs_scope(context).where.not(latency_ms: nil)
      current_p90 = AdminScreens::RecordingStudioAIWidgets.p90_latency(runs.where(created_at: 30.days.ago..Time.current))
      previous_p90 = AdminScreens::RecordingStudioAIWidgets.p90_latency(runs.where(created_at: 60.days.ago..30.days.ago))
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current_p90, previous: previous_p90)
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.latency_chart_rows(context, dimension: :model)
      [{ name: Copy.t("common.p90_latency_ms"), data: rows.map(&:p90_latency_ms) }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.latency_chart_rows(context, dimension: :model)
      {
        height: 240,
        plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
        xaxis: {
          categories: rows.map(&:name),
          min: 0,
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: {
          min: 0,
          labels: { show: true }
        },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("latency_by_model") }
  end
end
