# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def retry_rate_by_model_rows(scope, range: 30.days.ago..Time.current, limit: 3)
      runs = scope.where(created_at: range).where.not(resolved_model: nil)
      run_counts = runs.group(:resolved_model).count
      retried_run_counts = runs.where("retry_count > 0").group(:resolved_model).count

      run_counts.map do |model, count|
        [model, percentage(retried_run_counts.fetch(model, 0), count)]
      end.sort_by { |_model, rate| -rate }.first(limit)
    end

    def retry_rate_chart_rows(context, range: 30.days.ago..Time.current, limit: 3)
      memoize_widget([:retry_rate_chart_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        retry_rate_by_model_rows(site_runs_scope(context), range: range, limit: limit)
      end
    end

    def run_filtered_screen_path(context, screen_key, run = nil, extra: {})
      query = date_range_query(context, screen: AdminScreens::RecordingStudioAICallsScreen)
      query = query.merge(run_id: run.id) if run
      query = query.merge(extra)
      "#{context.admin_screen_path(screen_key)}?#{query.to_query}"
    end

    def top_model_call_volume_rows(context, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:top_model_call_volume_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        model_call_totals(site_runs_scope(context).where(created_at: range)).first(limit)
      end
    end

    def model_call_totals(runs)
      call_volume_totals(runs, group_by: :model)
    end

    def call_volume_group_by(context)
      value = context.filter_value(:group_by)
      value = "model" if value.blank?
      value.to_s == "provider" ? :provider : :model
    end

    def call_volume_totals(runs, group_by: :model)
      column = group_by.to_sym == :provider ? :resolved_provider : :resolved_model
      memoize_widget([:call_volume_totals, runs.object_id, column]) do
        runs.reorder(nil)
            .group(column)
            .count
            .each_with_object(Hash.new(0)) do |(value, count), totals|
              totals[value.presence || "Unknown"] += count.to_i
            end
            .sort_by { |label, count| [-count, label.to_s.downcase] }
      end
    end
  end
end
