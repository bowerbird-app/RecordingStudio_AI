# frozen_string_literal: true

module AdminScreens
  # Admin's built-in group_by filter only accepts time buckets. This definition
  # keeps the Group by control but switches between model and provider bars.
  class CallVolumeGroupByFilterDefinition
    ALLOWED = %w[model provider].freeze

    attr_reader :key, :type, :options

    def initialize(options = {})
      @key = :group_by
      @type = :group_by
      @options = options
    end

    def param_key
      (options[:param] || key).to_sym
    end

    def allowed_values
      ALLOWED.dup
    end

    def normalize(params)
      raw = params[param_key] || params[param_key.to_s]
      value = raw.to_s
      return default_value if value.empty?

      ALLOWED.include?(value) ? value.to_sym : default_value
    end

    def apply(relation, _value, _context)
      relation
    end

    private

    def default_value
      default = (options[:default] || :model).to_s
      (ALLOWED.include?(default) ? default : ALLOWED.first).to_sym
    end
  end

  class RecordingStudioAICallsByProviderModelScreen < RecordingStudioAdmin::Screen
    class << self
      def filter(name, **options)
        if name.to_sym == :group_by
          @filters_value << CallVolumeGroupByFilterDefinition.new(options)
        else
          super
        end
      end
    end

    key "calls_by_provider_model"
    icon :chart_bar
    title "Calls by provider/model"
    subtitle "Where call volume sits across providers and models."

    query do |context|
      AdminScreens::RecordingStudioAIWidgets.runs_scope(context).order(created_at: :desc)
    end

    filter_presentation :modal, inline_count: 3
    filter :date_range, field: :created_at, default: :last_4_weeks
    filter :group_by,
           values: %i[model provider],
           default: :model,
           apply: ->(relation, _value, _context) { relation }
    filter :provider,
           values: -> { AdminScreens::RecordingStudioAIWidgets.registered_provider_keys },
           apply: ->(relation, value, _context) { relation.where(resolved_provider: value) }
    filter :prompt,
           field: :prompt_key,
           values: -> { AdminScreens::RecordingStudioAIWidgets.run_present_distinct_values(:prompt_key) },
           apply: ->(relation, value, _context) { relation.where(prompt_key: value) }
    filter :status,
           param: :run_status,
           field: :status,
           options: -> { AdminScreens::RecordingStudioAIWidgets.run_distinct_values(:status) },
           apply: ->(relation, value, _context) { relation.where(status: value.to_s) }
    filter :model,
           field: :resolved_model,
           values: -> { AdminScreens::RecordingStudioAIWidgets.registered_model_keys },
           apply: ->(relation, value, _context) { relation.where(resolved_model: value) }

    summary do
      change_good_when :up
    end

    chart do
      title do |context|
        AdminScreens::RecordingStudioAIWidgets.call_volume_group_by(context) == :provider ? "Calls by provider" : "Calls by model"
      end
      subtitle "All groups in the selected date range."
      type :bar
      series do |context|
        rows = AdminScreens::RecordingStudioAIWidgets.call_volume_totals(
          context.query_result.relation,
          group_by: AdminScreens::RecordingStudioAIWidgets.call_volume_group_by(context)
        )
        [{ name: "Calls", data: rows.map { |_label, count| count.to_i } }]
      end
      options do |context|
        rows = AdminScreens::RecordingStudioAIWidgets.call_volume_totals(
          context.query_result.relation,
          group_by: AdminScreens::RecordingStudioAIWidgets.call_volume_group_by(context)
        )
        {
          height: [300, (rows.length * 40) + 80].max,
          plotOptions: { bar: { horizontal: true, barHeight: "55%" } },
          xaxis: {
            categories: rows.map { |label, _count| label },
            min: 0
          },
          dataLabels: { enabled: false }
        }
      end
    end

    table do
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
      column :total_tokens, title: "Tokens", header_tooltip: "Rough size of what went in and came back."
      column :latency_ms, title: "Latency (ms)", header_tooltip: "How long this call took."

      default_columns :created_at, :prompt_name_snapshot, :status, :resolved_provider, :resolved_model, :total_tokens,
                      :latency_ms
      default_sort :created_at, direction: :desc
      paginate per_page: 25
    end
  end
end
