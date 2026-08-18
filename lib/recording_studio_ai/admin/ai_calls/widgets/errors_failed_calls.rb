# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIErrorsFailedCallsWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.errors_failed_calls") do
    type :chart
    title "Errors / failed calls"
    subtitle "Weekly failed-call volume for the last 4 weeks."
    description "Failure count trend to monitor reliability and regressions."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      AdminScreens::RecordingStudioAIWidgets.number(
        failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.trailing_weeks_range(weeks_back: 4)).count
      )
    end
    change do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      current = failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.this_week_range).count
      previous = failed_runs.where(created_at: AdminScreens::RecordingStudioAIWidgets.previous_week_range).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :down
    chart_type :line
    series do |context|
      failed_runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(status: "failed")
      AdminScreens::RecordingStudioAIWidgets.weekly_calls_series(
        failed_runs,
        weeks_back: 4,
        series_name: "Failed calls"
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
    link_to { |context| "#{context.admin_screen_path('ai_calls')}?run_status=failed" }
  end
end
