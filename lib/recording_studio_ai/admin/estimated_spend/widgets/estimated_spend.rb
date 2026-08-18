# frozen_string_literal: true

module AdminScreens
  RecordingStudioAIEstimatedSpendWidget = RecordingStudioAdmin::Widget.new("widgets.recording_studio_ai.estimated_spend") do
    type :chart
    title "Estimated token/model spend"
    subtitle "Top 5 models by token usage in the last 30 days."
    description "Ranks models by token usage so spend concentration is immediately visible."
    metadata { { period_label: "Last 30 days" } }
    value do |context|
      runs = AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
      total_tokens = runs.where(created_at: 30.days.ago..Time.current).where.not(total_tokens: nil).sum(:total_tokens)
      AdminScreens::RecordingStudioAIWidgets.number(total_tokens)
    end
    change do |context|
      now = Time.current
      AdminScreens::RecordingStudioAIWidgets.token_change_label(
        AdminScreens::RecordingStudioAIWidgets.runs_scope(context),
        current_range: 30.days.ago..now,
        previous_range: 60.days.ago..30.days.ago
      )
    end
    change_good_when :down
    chart_type :bar
    series do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_token_chart_rows(context)

      [{
        name: "Token usage",
        data: rows.map { |_model, total_tokens| total_tokens.to_i }
      }]
    end
    chart_options do |context|
      rows = AdminScreens::RecordingStudioAIWidgets.top_model_token_chart_rows(context)

      {
        height: 240,
        plotOptions: {
          bar: {
            horizontal: true,
            barHeight: "55%"
          }
        },
        xaxis: {
          categories: rows.map { |model, _total_tokens| model.presence || "Unknown" },
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
    link_to { |context| context.admin_screen_path("estimated_spend") }
  end
end
