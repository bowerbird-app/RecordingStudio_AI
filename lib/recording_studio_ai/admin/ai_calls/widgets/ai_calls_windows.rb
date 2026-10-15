# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIAICallsWindowsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.ai_calls_windows") do
    type :chart
    title { Copy.t("admin.widgets.ai_calls_windows.title") }
    subtitle { Copy.t("admin.widgets.ai_calls_windows.subtitle") }
    description { Copy.t("admin.widgets.ai_calls_windows.description") }
    metadata { { period_label: Copy.t("common.last_30_days") } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      AdminScreens::RecordingStudioAIWidgets.number(
        runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4)).count
      )
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      current = runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :line
    series do |context|
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        weeks_back: 4,
        series_name: Copy.t("common.ai_calls")
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
    link_to { |context| context.admin_screen_path("ai_calls") }
  end
end
