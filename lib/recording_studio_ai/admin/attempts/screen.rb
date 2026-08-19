# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIAttemptsScreen < RecordingStudioAdmin::Screen
    key "attempts"
    icon :arrow_path
    title "Attempts"
    subtitle "Provider attempts for AI calls, ordered by their execution sequence."

    query do |context|
      relation = AdminScreens::RecordingStudioAIWidgets.attempts_scope(context)
      relation.includes(:run).preload(:requested_custom_tool_invocations).order(:sequence)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by, values: %i[hour day week month year], default: :day
    filter :status,
           param: :attempt_status,
           field: :status,
           options: -> { AdminScreens::RecordingStudioAIWidgets.attempt_distinct_values(:status) },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :provider,
           field: :provider,
           values: -> { AdminScreens::RecordingStudioAIWidgets.attempt_distinct_values(:provider) },
           apply: ->(relation, value, _context) { relation.where(provider: value) }
    filter :model,
           field: :model,
           values: -> { AdminScreens::RecordingStudioAIWidgets.attempt_distinct_values(:model) },
           apply: ->(relation, value, _context) { relation.where(model: value) }
    filter :prompt,
           field: :prompt_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_key) },
           apply: lambda { |relation, value, _context|
             relation.where(run_id: RecordingStudioAI::Run.where(prompt_key: value).select(:id))
           }
    filter :token_min,
           param: :min_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             value.to_i.positive? ? relation.where("recording_studio_ai_attempts.total_tokens >= ?", value.to_i) : relation
           }
    filter :token_max,
           param: :max_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             if value.to_i.positive? && value.to_i < 1_000_000
               relation.where("recording_studio_ai_attempts.total_tokens <= ?", value.to_i)
             else
               relation
             end
           }
    filter :error_code,
           field: :error_code,
           values: -> { AdminScreens::RecordingStudioAIWidgets.attempt_present_distinct_values(:error_code) },
           apply: ->(relation, value, _context) { relation.where(error_code: value.to_s) }
    filter :run_id,
           field: :run_id,
           apply: ->(relation, value, _context) { relation.where(run_id: value) }
    filter :kind,
           field: :kind,
           values: -> { AdminScreens::RecordingStudioAIWidgets.attempt_distinct_values(:kind) },
           apply: ->(relation, value, _context) { relation.where(kind: value) }

    summary do
      change_good_when do |context|
        kind = context.filter_value(:kind).to_s
        status = context.filter_value(:status).to_s
        if %w[retry fallback continuation].include?(kind) || %w[failed cancelled].include?(status)
          :down
        else
          :up
        end
      end
    end

    chart do
      title "Attempts by kind"
      subtitle "Stacked attempt volume by primary, retry, fallback, and continuation."
      type :column
      series do |context|
        AdminScreens::RecordingStudioAIWidgets.attempt_kind_series(
          context.query_result.relation,
          date_range: context.filter_value(:date_range),
          bucket: context.filter_value(:group_by) || :day
        )
      end
      options do
        {
          height: 300,
          chart: { stacked: true },
          plotOptions: {
            bar: {
              horizontal: false,
              columnWidth: "55%"
            }
          },
          xaxis: {
            labels: { show: true },
            axisBorder: { show: false },
            axisTicks: { show: false }
          },
          yaxis: { min: 0 },
          legend: { position: "top" },
          grid: { xaxis: { lines: { show: false } } }
        }
      end
    end

    table do
      show_columns_button

      column :created_at, title: "Created", header_tooltip: "When this try happened."
      column :run_id, title: "AI call", header_tooltip: "The call this try belongs to."
      column :sequence, title: "Sequence", header_tooltip: "Order of tries on that call."
      column :kind,
             header_tooltip: "First try, a retry, or a switch to another provider.",
             display: :badge,
             display_options: lambda { |_row, _context, value|
               { text: value.to_s.humanize, style: :default, size: :sm }
             }
      column :prompt,
             title: "Prompt",
             sortable: false,
             header_tooltip: "The prompt this try used.",
             value: lambda { |attempt, _context|
               attempt.run&.prompt_name_snapshot.presence || attempt.run&.prompt_key || "No prompt"
             }
      column :tools,
             title: "Tools",
             sortable: false,
             header_tooltip: "Tools this try used, by name.",
             value: lambda { |attempt, _context|
               names = attempt.requested_custom_tool_invocations.sort_by(&:id).filter_map do |invocation|
                 invocation.tool_name_snapshot.presence || invocation.tool_key.presence
               end.uniq
               names.join(", ").presence
             }
      column :status,
             header_tooltip: "How this try ended.",
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
      column :provider, header_tooltip: "Who we asked."
      column :model, header_tooltip: "The model that served this try."
      column :latency_ms, title: "Latency (ms)", header_tooltip: "How long this try took."
      column :total_tokens, title: "Tokens", header_tooltip: "Rough size of what went in and came back."
      column :error_code, title: "Error code", header_tooltip: "Why it failed, when it failed."

      default_columns :created_at, :prompt, :tools, :status, :provider, :model, :latency_ms, :total_tokens, :error_code

      default_sort :sequence, direction: :asc
      paginate per_page: 25
    end

    table.extend(AdminScreens::RecordingStudioAIWidgets::AttemptErrorCodeColumn)
  end
end
