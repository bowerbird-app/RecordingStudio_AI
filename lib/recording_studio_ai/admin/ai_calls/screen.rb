# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAICallsScreen < RecordingStudioAdmin::Screen
    key "ai_calls"
    icon :cpu_chip
    title "AI Calls"
    subtitle "Run-level execution history across generation, streaming, and batch operations."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:status) },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :operation,
           field: :operation,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:operation) }
    filter :prompt,
           title: "Prompt",
           field: :prompt_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_key) }
    filter :prompt_version,
           title: "Prompt version",
           field: :prompt_version,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_version) },
           apply: ->(relation, value, _context) { relation.where(prompt_version: value) }
    filter :provider,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:resolved_provider) },
           apply: ->(relation, value, _context) { relation.where(resolved_provider: value) }
    filter :tool_key,
           param: :custom_tool_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.tool_distinct_values(:tool_key) },
           apply: lambda { |relation, value, _context|
             relation.where(id: RecordingStudioAI::CustomToolInvocation.where(tool_key: value).select(:run_id))
           }
    filter :model,
           field: :resolved_model,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:resolved_model) },
           apply: ->(relation, value, _context) { relation.where(resolved_model: value) }
    filter :slowest,
           values: [ "1" ],
           control: :checkbox,
           apply: lambda { |relation, _value, _context|
             relation.where.not(latency_ms: nil).reorder(latency_ms: :desc)
           }

    summary do
      change_good_when do |context|
        %w[failed cancelled].include?(context.filter_value(:status).to_s) ? :down : :up
      end
    end

    chart do
      title "AI calls trend"
      subtitle "How many calls landed over time."
      type :line
      series do |context|
        [{
          name: "AI calls",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: "recording_studio_ai_runs.created_at",
            bucket: context.filter_value(:group_by) || :day
          )
        }]
      end
      options do
        {
          height: 300,
          stroke: { curve: "smooth", width: 3 },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "status ILIKE :search",
              "operation ILIKE :search",
              "profile_key ILIKE :search",
              "requested_provider ILIKE :search",
              "resolved_provider ILIKE :search",
              "resolved_model ILIKE :search",
              "prompt_key ILIKE :search",
              "prompt_name_snapshot ILIKE :search",
              "CAST(id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :created_at, title: "Created", header_tooltip: "When this call started."
      column :run,
             title: "Run",
             sortable: false,
             header_tooltip: "Open the run detail page.",
             value: lambda { |run, _context|
               ActionController::Base.helpers.link_to(
                 "Run ##{run.id}",
                 "/recording_studio_ai/admin/runs/#{run.id}",
                 class: "text-(--color-primary-background-color) underline",
                 data: { turbo_frame: "_top" }
               )
             }
      column :status,
             header_tooltip: "How the call ended.",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :profile_key, title: "Profile", header_tooltip: "Which speed and quality mix was asked for."
      column :prompt_name_snapshot, title: "Prompt", header_tooltip: "The prompt this call used."
      column :requested_provider, title: "Requested", header_tooltip: "The provider someone asked for."
      column :resolved_provider, title: "Resolved", header_tooltip: "The provider that actually ran it."
      column :resolved_model, title: "Model", header_tooltip: "The model that served this call."
      column :attempt_count,
             title: "Attempts",
             header_tooltip: "How many tries this call took. Open it to see them.",
             value: lambda { |run, context|
               count = run.attempt_count.to_i
               next count if count.zero?

               ActionController::Base.helpers.link_to(
                 count,
                 AdminScreens::RecordingStudioAIWidgets.run_filtered_screen_path(context, "attempts", run),
                 class: "text-(--color-primary-background-color)",
                 data: { turbo_frame: "_top" }
               )
             }
      column :custom_tool_invocation_count,
             title: "Tool calls",
             header_tooltip: "How many tools this call used. Open it to see them.",
             value: lambda { |run, context|
               count = run.custom_tool_invocation_count.to_i
               next count if count.zero?

               ActionController::Base.helpers.link_to(
                 count,
                 AdminScreens::RecordingStudioAIWidgets.run_filtered_screen_path(context, "tool_calls", run),
                 class: "text-(--color-primary-background-color)",
                 data: { turbo_frame: "_top" }
               )
             }
      column :total_tokens, title: "Tokens", header_tooltip: "Rough size of what went in and came back."
      column :latency_ms, title: "Latency (ms)", header_tooltip: "How long this call took."

      default_sort :latency_ms, direction: :desc
      paginate per_page: 25
    end
  end
end
