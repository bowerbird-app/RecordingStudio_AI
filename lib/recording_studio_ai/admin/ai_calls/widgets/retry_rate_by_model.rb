# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIRetryRateByModelWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.retry_rate_by_model") do
    type :chart
    title { Copy.t("admin.widgets.retry_rate_by_model.title") }
    subtitle { Copy.t("admin.widgets.retry_rate_by_model.subtitle") }
    description { Copy.t("admin.widgets.retry_rate_by_model.description") }
    metadata { { period_label: Copy.t("common.last_30_days") } }
    value do |context|
      retries = AdminScreens::RecordingStudioAIWidgets.site_runs_scope(context)
                                                      .where(created_at: 30.days.ago..Time.current)
                                                      .sum(:retry_count)
      AdminScreens::RecordingStudioAIWidgets.number(retries)
    end
    change do |context|
      scope = AdminScreens::RecordingStudioAIWidgets.site_runs_scope(context)
      now = Time.current
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(
        current: scope.where(created_at: 30.days.ago..now).sum(:retry_count),
        previous: scope.where(created_at: 60.days.ago..30.days.ago).sum(:retry_count)
      )
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_chart_rows(context)
      [{ name: Copy.t("common.retry_rate"), data: rows.map(&:last) }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.retry_rate_chart_rows(context)
      {
        height: 240,
        plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
        xaxis: {
          categories: rows.map(&:first),
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: { labels: { show: true } },
        dataLabels: { enabled: false },
        tooltip: { y: { formatter: "function(value) { return value + '%'; }" } },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("attempts") }
  end
end
