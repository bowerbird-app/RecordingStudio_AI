# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIRunsHealthScreen < RecordingStudioAdmin::Screen
    key "ai_runs_health"
    icon :shield_exclamation
    title { Copy.t("admin.screens.ai_runs_health.title") }
    subtitle { Copy.t("admin.screens.ai_runs_health.subtitle") }

    query do |context|
      RecordingStudioAI::Admin::RunsHealth.profile_token_rows(context)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_30_days
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :profile,
           title: "Profile",
           field: :profile_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.site_run_present_distinct_values(:profile_key) },
           apply: ->(relation, _value, _context) { relation }
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { AdminScreens::RecordingStudioAIWidgets.site_run_distinct_values(:status) },
           apply: ->(relation, _value, _context) { relation }
    filter :stuck,
           title: "Stuck",
           values: [ "1" ],
           control: :checkbox,
           apply: ->(relation, _value, _context) { relation }

    summary do
      hide_change
      value do |context|
        RecordingStudioAI::Admin::RunsHealth.headline_count(context)
      end
      period_label do |context|
        RecordingStudioAI::Admin::RunsHealth.change_markup(context)
      end
    end

    chart do
      title { Copy.t("admin.screens.ai_runs_health.chart_title") }
      subtitle { Copy.t("admin.screens.ai_runs_health.chart_subtitle") }
      type :line
      series do |context|
        RecordingStudioAI::Admin::RunsHealth.chart_series(context)
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
