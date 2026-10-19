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

    summary do
      label { Copy.t("admin.screens.ai_runs_health.stuck_label") }
      change_good_when :down
      value do |context|
        RecordingStudioAI::Admin::MetricRead.scalar("ai_runs.stuck", admin_context: context).to_i
      end
      hide_change
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

    widget "widgets.recording_studio_ai.fallback_retry_rate"

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
