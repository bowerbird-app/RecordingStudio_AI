# frozen_string_literal: true

module AdminScreens
  class RecordingStudioAIEstimatedSpendScreen < RecordingStudioAdmin::Screen
    key "estimated_spend"
    icon :currency_dollar
    title "Estimated token usage"
    subtitle "How much we sent and got back, by model."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context)
                                            .where.not(total_tokens: nil)
                                            .order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:status) },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :model,
           field: :resolved_model,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:resolved_model) },
           apply: ->(relation, value, _context) { relation.where(resolved_model: value) }
    filter :provider,
           field: :resolved_provider,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:resolved_provider) },
           apply: ->(relation, value, _context) { relation.where(resolved_provider: value) }
    filter :prompt,
           field: :prompt_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_key) },
           apply: ->(relation, value, _context) { relation.where(prompt_key: value) }
    filter :token_min,
           param: :min_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             value.to_i.positive? ? relation.where("total_tokens >= ?", value.to_i) : relation
           }
    filter :token_max,
           param: :max_tokens,
           max: 1_000_000,
           apply: lambda { |relation, value, _context|
             value.to_i.positive? && value.to_i < 1_000_000 ? relation.where("total_tokens <= ?", value.to_i) : relation
           }

    summary do
      label "Tokens"
      change_good_when :down
      value do |context|
        context.query_result.relation.except(:order).sum(:total_tokens)
      end
      previous_value do |context|
        widgets = AdminScreens::RecordingStudioAIWidgets
        previous = widgets.previous_period_date_range(context.filter_value(:date_range))
        widgets.token_total_for_range(context, date_range: previous)
      end
    end

    chart do
      title "Token usage by model"
      subtitle "All models in the selected date range."
      type :bar
      series do |context|
        rows = AdminScreens::RecordingStudioAIWidgets.model_token_totals(context.query_result.relation)
        [{ name: "Tokens", data: rows.map { |_model, total_tokens| total_tokens.to_i } }]
      end
      options do |context|
        rows = AdminScreens::RecordingStudioAIWidgets.model_token_totals(context.query_result.relation)
        {
          height: [300, (rows.length * 40) + 80].max,
          plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
          xaxis: {
            categories: rows.map { |model, _total_tokens| model.presence || "Unknown" },
            min: 0
          },
          dataLabels: { enabled: false }
        }
      end
    end

    table do
      column :id, title: "Run", header_tooltip: "This call's id."
      column :created_at, title: "Created", header_tooltip: "When this call started."
      column :prompt_name_snapshot,
             title: "Prompt",
             sortable: false,
             header_tooltip: "The prompt this call used.",
             value: ->(run, _context) { run.prompt_name_snapshot.presence || run.prompt_key || "No prompt" }
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
      column :resolved_provider, title: "Provider", header_tooltip: "Who we asked."
      column :resolved_model, title: "Model", header_tooltip: "The model that served this call."
      column :total_tokens, title: "Total tokens", header_tooltip: "Rough size of the whole call."
      column :input_tokens, title: "Input", header_tooltip: "Size of what we sent."
      column :output_tokens, title: "Output", header_tooltip: "Size of what came back."

      default_columns :created_at, :prompt_name_snapshot, :status, :resolved_provider, :resolved_model, :total_tokens,
                      :input_tokens, :output_tokens

      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
