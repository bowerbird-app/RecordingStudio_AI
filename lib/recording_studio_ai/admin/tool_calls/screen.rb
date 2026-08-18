# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIToolCallsScreen < RecordingStudioAdmin::Screen
    key "tool_calls"
    icon :wrench_screwdriver
    title "Custom Tool Calls"
    subtitle "Custom tool invocation history with status, confirmation, and latency signals."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.tool_scope(context).includes(:run).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :tool_key,
           field: :tool_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.tool_distinct_values(:tool_key) }
    filter :run_id,
           field: :run_id,
           apply: ->(relation, value, _context) { relation.where(run_id: value) }
    filter :status,
           param: :tool_status,
           field: :status,
           options: -> { RecordingStudioAI::CustomToolInvocation::STATUSES.values },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :prompt,
           field: :prompt_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_key) },
           apply: lambda { |relation, value, _context|
             relation.where(run_id: RecordingStudioAI::Run.where(prompt_key: value).select(:id))
           }

    summary do
      change_good_when do |context|
        %w[denied failed rejected].include?(context.filter_value(:status).to_s) ? :down : :up
      end
    end

    chart do
      title "Custom tool calls trend"
      subtitle "Custom tool call volume over time."
      type :line
      series do |context|
        [{
          name: "Tool calls",
          data: RecordingStudioAdmin::AdminActivityLogsSupport.date_series(
            context.query_result.relation.reorder(nil),
            field: "recording_studio_ai_custom_tool_invocations.created_at",
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
      show_columns_button
      filter :search, apply: lambda { |relation, value, _context|
        if value.present?
          search = "%#{ActiveRecord::Base.sanitize_sql_like(value.to_s.strip)}%"

          relation.where(
            [
              "status ILIKE :search",
              "tool_key ILIKE :search",
              "tool_name_snapshot ILIKE :search",
              "provider_tool_call_id ILIKE :search",
              "error_category ILIKE :search",
              "error_code ILIKE :search",
              "error_message ILIKE :search",
              "CAST(id AS TEXT) ILIKE :search",
              "CAST(run_id AS TEXT) ILIKE :search"
            ].join(" OR "),
            search: search
          )
        else
          relation
        end
      }

      column :id, title: "Invocation", header_tooltip: "This tool run's id."
      column :created_at, title: "Created", header_tooltip: "When this tool ran."
      column :run_id, title: "Run", header_tooltip: "The AI call that asked for this tool."
      column :tool_key, title: "Tool", header_tooltip: "Which tool ran."
      column :prompt,
             title: "Prompt",
             sortable: false,
             header_tooltip: "The prompt that asked for this tool.",
             value: lambda { |invocation, _context|
               invocation.run&.prompt_name_snapshot.presence || invocation.run&.prompt_key || "No prompt"
             }
      column :tool_version, title: "Version",
                            header_tooltip: "Which version of the tool ran."
      column :status,
             header_tooltip: "How this tool run ended.",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               style = case value.to_s
                       when "completed" then :success
                       when "failed", "denied", "rejected" then :danger
                       when "cancelled" then :warning
                       else :default
                       end
               { text: value.to_s.humanize, style: style, size: :sm }
             }
      column :confirmation_status, title: "Confirmation", header_tooltip: "Whether someone said yes first."
      column :requires_confirmation, title: "Needs confirm",
                                     header_tooltip: "This tool waits for a yes before it runs."
      column :read_only, title: "Read-only", header_tooltip: "This tool only looks. It does not change anything."
      column :destructive, title: "Destructive", header_tooltip: "This tool can change or delete something."
      column :latency_ms, title: "Latency (ms)", header_tooltip: "How long this tool took."
      column :error_code, title: "Error code",
                          header_tooltip: "Why it failed, when it failed."

      default_columns :created_at, :tool_key, :prompt, :status, :latency_ms

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
