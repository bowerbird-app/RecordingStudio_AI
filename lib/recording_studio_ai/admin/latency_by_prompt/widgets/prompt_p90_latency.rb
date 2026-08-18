# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIPromptP90LatencyWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.prompt_p90_latency") do
    type :chart
    title "Prompt P90 latency"
    subtitle "Top 5 prompts by P90 latency over the last 30 days."
    description "Compares prompt response speed using the latency at or below which 90% of calls completed."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      p90_latency = AdminScreens::RecordingStudioAIWidgets.latency_chart_rows(context, dimension: :prompt)
                                                          .first&.p90_latency_ms.to_i
      "#{AdminScreens::RecordingStudioAIWidgets.number(p90_latency)} ms"
    end
    change do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context).where.not(latency_ms: nil)
      current_p90 = AdminScreens::RecordingStudioAIWidgets.latency_rows_for_runs(
        runs.where(created_at: 30.days.ago..Time.current), dimension: :prompt
      ).first&.p90_latency_ms.to_i
      previous_p90 = AdminScreens::RecordingStudioAIWidgets.latency_rows_for_runs(
        runs.where(created_at: 60.days.ago..30.days.ago), dimension: :prompt
      ).first&.p90_latency_ms.to_i
      AdminScreens::RecordingStudioAIWidgets.percentage_change_label(current: current_p90, previous: previous_p90)
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.latency_chart_rows(context, dimension: :prompt)
      [{ name: "P90 latency (ms)", data: rows.map(&:p90_latency_ms) }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.latency_chart_rows(context, dimension: :prompt)
      {
        height: 240,
        plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
        xaxis: { categories: rows.map(&:name), min: 0, labels: { show: false } },
        yaxis: { labels: { show: true } },
        dataLabels: { enabled: false },
        grid: { xaxis: { lines: { show: false } } }
      }
    end
    link_to { |context| context.admin_screen_path("latency_by_prompt") }
  end
end
