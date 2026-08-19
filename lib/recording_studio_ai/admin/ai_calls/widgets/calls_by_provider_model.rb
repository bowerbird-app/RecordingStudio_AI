# frozen_string_literal: true

module AdminScreens
  RecordingStudioAICallsByProviderModelWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.calls_by_provider_model") do
    type :chart
    title "Calls by provider/model"
    subtitle "Top 5 models by call volume in the last 30 days."
    description "Ranks models by call count so usage concentration is easy to compare."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where(created_at: 30.days.ago..Time.current)
      AdminScreens::RecordingStudioAIWidgets.number(runs.count)
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      current = runs.where(created_at: 30.days.ago..Time.current).count
      previous = runs.where(created_at: 60.days.ago..30.days.ago).count
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current, previous: previous)
    end
    change_good_when :up
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_call_volume_rows(context)

      [{
        name: "Call volume",
        data: rows.map { |_model, count| count.to_i }
      }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_call_volume_rows(context)

      {
        height: 240,
        plotOptions: {
          bar: {
            horizontal: true,
            barHeight: "55%"
          }
        },
        xaxis: {
          categories: rows.map { |model, _count| model.presence || "Unknown" },
          labels: { show: false },
          axisBorder: { show: false },
          axisTicks: { show: false }
        },
        yaxis: {
          labels: { show: true }
        },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("calls_by_provider_model") }
  end
end
