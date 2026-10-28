# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def model_rows(context)
      date_range = 30.days.ago.beginning_of_day..Time.current
      range_runs = runs_scope(context)
                   .where(created_at: date_range)
                   .where.not(resolved_model: [nil, ""])
      call_counts = range_runs.group(:resolved_provider, :resolved_model).count
      daily_counts = grouped_daily_counts(
        range_runs,
        :resolved_provider,
        :resolved_model,
        column: "#{RecordingStudioAI::Run.table_name}.created_at"
      )

      rows = RecordingStudioAI.models.all.map do |definition|
        provider_key = definition.provider.to_s
        model_key = definition.model
        ModelRow.new(
          provider_key,
          model_key,
          parameter_default_label(definition, :temperature),
          parameter_default_label(definition, :verbosity),
          parameter_default_label(definition, :reasoning_effort),
          definition.delivery.fetch(:streaming, false),
          definition.delivery.fetch(:structured_output, false),
          definition.delivery.fetch(:batch, false),
          definition.tools.map(&:to_s).join(", "),
          definition.modalities.fetch(:input, []).map(&:to_s).join(", "),
          definition.modalities.fetch(:output, []).map(&:to_s).join(", "),
          call_counts.fetch([provider_key, model_key], 0),
          (date_range.begin.to_date..date_range.end.to_date).map do |date|
            { x: date.strftime("%b %-d"), y: daily_counts.fetch([provider_key, model_key, date], 0) }
          end
        )
      end
      filter_model_rows_by_provider(rows, context).sort_by { |row| [-row.calls, row.provider, row.model] }
    end

    def registered_model_keys
      RecordingStudioAI.models.all.map { |definition| definition.model.to_s }.uniq.sort
    end

    def registered_models_path(context, provider:)
      "#{context.admin_screen_path('registered_models')}?#{{ provider: provider }.to_query}"
    end

    def filter_model_rows_by_provider(rows, context)
      return rows unless context.respond_to?(:filter_value)

      provider = context.filter_value(:provider).to_s.presence
      return rows if provider.blank?

      rows.select { |row| row.provider.to_s == provider }
    end

    def parameter_default_label(definition, name)
      return "—" unless definition.supports_parameter?(name)

      value = definition.parameter(name)&.fetch(:default, nil)
      value.nil? ? "Supported" : value.to_s
    end

    def top_model_call_rows(context, range: 30.days.ago..Time.current, limit: 5)
      counts = site_runs_scope(context)
               .where(created_at: range)
               .where.not(resolved_model: [nil, ""])
               .group(:resolved_provider, :resolved_model)
               .count

      rows = RecordingStudioAI.models.all.map do |definition|
        [
          definition.provider.to_s,
          definition.model,
          definition.display_name,
          counts.fetch([definition.provider.to_s, definition.model], 0)
        ]
      end
      rows.sort_by { |_provider, _model, _name, calls| -calls }.first(limit)
    end
  end
end
