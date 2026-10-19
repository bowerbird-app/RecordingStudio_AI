# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIToolCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.tool_calls") do
    type :chart
    title { Copy.t("admin.widgets.tool_calls.title") }
    subtitle { Copy.t("admin.widgets.tool_calls.subtitle") }
    description { Copy.t("admin.widgets.tool_calls.description") }
    metadata { { period_label: Copy.t("common.last_30_days") } }
    value do |context|
      count = AdminScreens::RecordingStudioAIWidgets.site_tool_scope(context)
                                                    .where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4))
                                                    .count
      AdminScreens::RecordingStudioAIWidgets.number(count)
    end
    change do |context|
      scope = AdminScreens::RecordingStudioAIWidgets.site_tool_scope(context)
      current = scope.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = scope.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :line
    series do |context|
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        AdminScreens::RecordingStudioAIWidgets.site_tool_scope(context),
        weeks_back: 4,
        series_name: Copy.t("common.tool_calls")
      )
    end
    chart_options do
      {
        height: 240,
        stroke: { curve: "smooth", width: 3 },
        xaxis: {
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        grid: { xaxis: { lines: { show: false } } },
        yaxis: { min: 0, labels: { show: false } }
      }
    end
    link_to { |context| context.admin_screen_path("tool_calls") }
  end
end
