# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def p90_latency(scope)
      count = scope.count
      return 0 if count.zero?

      offset = [(count * 0.9).ceil - 1, 0].max
      scope.order(:latency_ms).offset(offset).limit(1).pick(:latency_ms).to_i
    end

    def daily_p90_latency_series(scope, range: 30.days.ago..Time.current)
      rows = scope.where(created_at: range).pluck(:created_at, :latency_ms)
      rows.group_by { |created_at, _latency_ms| created_at.to_date }.sort_by(&:first).map do |date, day_rows|
        { x: date.strftime("%b %-d"), y: percentile_latency(day_rows.map(&:last), percentile: 0.9) }
      end
    end

    def percentile_latency(latencies, percentile:)
      values = latencies.compact.map(&:to_i).sort
      return 0 if values.empty?

      values[(values.length * percentile).ceil - 1]
    end

    def latency_rows(context, dimension:)
      date_range = latency_date_range(context, dimension: dimension)
      runs = runs_scope(context).where(created_at: date_range).where.not(latency_ms: nil)
      latency_rows_for_runs(runs, dimension: dimension, date_range: date_range)
    end

    def latency_chart_rows(context, dimension:, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:latency_chart_rows, context.object_id, dimension, range.begin.to_f, range.end.to_f, limit]) do
        latency_rows_for_runs(
          site_runs_scope(context).where(created_at: range).where.not(latency_ms: nil),
          dimension: dimension
        ).first(limit)
      end
    end

    def latency_rows_for_runs(runs, dimension:, date_range: nil)
      grouped_latencies = runs.pluck(:resolved_model, :prompt_name_snapshot, :prompt_key,
                                     :prompt_version, :latency_ms, :created_at).group_by do |row|
        latency_row_group_key(row, dimension: dimension)
      end

      grouped_latencies.map do |identity, rows|
        latencies = rows.map { |row| row[4] }
        LatencyRow.new(
          identity.fetch(:name),
          latencies.length,
          latency_calls_series(rows, date_range: date_range),
          percentile_latency(latencies, percentile: 0.5),
          percentile_latency(latencies, percentile: 0.9),
          (latencies.sum.to_f / latencies.length).round,
          latencies.max,
          identity[:prompt_key],
          identity[:prompt_version],
          identity[:resolved_model]
        )
      end.sort_by { |row| [-row.p90_latency_ms, row.name] }
    end

    def latency_row_group_key(row, dimension:)
      model, prompt_name, prompt_key, prompt_version, = row
      if dimension == :model
        { name: model.presence || Copy.t("common.unknown_model"),
          resolved_model: model.presence }
      else
        name = if prompt_name.present?
                 "#{prompt_name}#{" v#{prompt_version}" if prompt_version.present?}"
               else
                 prompt_key.presence || Copy.t("common.no_prompt")
               end
        {
          name: name,
          prompt_key: prompt_key,
          prompt_version: prompt_version
        }
      end
    end

    def latency_calls_series(rows, date_range:)
      return [] unless date_range&.begin && date_range.end

      daily_counts = rows.each_with_object(Hash.new(0)) do |row, counts|
        created_at = row.last
        next if created_at.blank?

        counts[created_at.to_date] += 1
      end

      (date_range.begin.to_date..date_range.end.to_date).map do |date|
        { x: date.strftime("%b %-d"), y: daily_counts.fetch(date, 0) }
      end
    end

    def latency_prompt_calls_path(context, row)
      latency_calls_path(
        context,
        screen: AdminScreens::RecordingStudioAILatencyByPromptScreen,
        prompt: row.prompt_key,
        prompt_version: row.prompt_version
      )
    end

    def latency_model_calls_path(context, row)
      latency_calls_path(
        context,
        screen: AdminScreens::RecordingStudioAILatencyByModelScreen,
        model: row.resolved_model
      )
    end

    def latency_calls_path(context, screen:, **filters)
      range_query = date_range_query(context, screen: screen)
      "/admin/screens/ai_calls?#{range_query.merge(filters.compact).to_query}"
    end

    def latency_date_range(context, dimension:)
      prompt_created_at_range(latency_date_range_value(context, dimension: dimension))
    end

    def latency_date_range_value(context, dimension:)
      selected = context.filter_value(:date_range)
      return selected if selected

      latency_screen_for(dimension).filters.find { |filter| filter.key == :date_range }.normalize(context.params)
    end

    def latency_screen_for(dimension)
      if dimension == :model
        AdminScreens::RecordingStudioAILatencyByModelScreen
      else
        AdminScreens::RecordingStudioAILatencyByPromptScreen
      end
    end

    def latency_summary_p90(context, dimension:, previous: false)
      date_range = latency_date_range_value(context, dimension: dimension)
      date_range = previous_period_date_range(date_range) if previous
      latency_p90_for_range(context, date_range: date_range)
    end

    def latency_p90_for_range(context, date_range:)
      range = date_range.is_a?(Range) ? date_range : prompt_created_at_range(date_range)
      return 0 unless range

      p90_latency(runs_scope(context).where(created_at: range).where.not(latency_ms: nil))
    end
  end
end
