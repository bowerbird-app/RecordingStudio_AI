# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRunsHealthScreen < RecordingStudioAdmin::Screen
    key "ai_runs_health"
    icon :shield_exclamation
    title { Copy.t("admin.screens.ai_runs_health.title") }
    subtitle { Copy.t("admin.screens.ai_runs_health.subtitle") }

    query do |context|
      RecordingStudioAI::Admin::MetricRead.profile_token_rows(context)
    end

    widget "widgets.recording_studio_ai.stuck"
    widget "widgets.recording_studio_ai.fallback_retry_rate"

    summary do
      hide_change
      value do |context|
        last = Array(
          RecordingStudioAI::Admin::MetricRead.call("ai_runs.failed_over_time", admin_context: context).data
        ).last
        last ? (last[:value] || last["value"]).to_i : 0
      end
    end

    chart do
      title { Copy.t("admin.screens.ai_runs_health.chart_title") }
      subtitle { Copy.t("admin.screens.ai_runs_health.chart_subtitle") }
      type :line
      series do |context|
        RecordingStudioAI::Admin::MetricRead.chart_series(
          "ai_runs.failed_over_time",
          admin_context: context,
          kind: :timeseries_groups,
          group_by: :error_category
        )
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      title { Copy.t("admin.screens.ai_runs_health.table_title") }
      hide_columns_button
      column :profile, title: "Profile", header_tooltip: "Which speed and quality mix used the tokens."
      column :tokens, title: "Tokens", header_tooltip: "Total tokens for that profile."
      default_columns :profile, :tokens
      paginate per_page: 25
    end
  end
end
