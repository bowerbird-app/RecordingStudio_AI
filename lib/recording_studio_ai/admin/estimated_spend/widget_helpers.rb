# frozen_string_literal: true

module AdminScreens
  module RecordingStudioAIWidgets
    def top_model_token_rows(scope, range:, limit: 5)
      scope.where(created_at: range)
           .where.not(total_tokens: nil)
           .group(:resolved_model)
           .sum(:total_tokens)
           .sort_by { |_model, total_tokens| -total_tokens.to_i }
           .first(limit)
    end

    def top_model_token_chart_rows(context, range: 30.days.ago..Time.current, limit: 5)
      memoize_widget([:top_model_token_chart_rows, context.object_id, range.begin.to_f, range.end.to_f, limit]) do
        top_model_token_rows(site_runs_scope(context), range: range, limit: limit)
      end
    end

    def model_token_totals(runs)
      memoize_widget([:model_token_totals, runs.object_id]) do
        runs.reorder(nil)
            .where.not(total_tokens: nil)
            .group(:resolved_model)
            .sum(:total_tokens)
            .each_with_object(Hash.new(0)) do |(model, total_tokens), totals|
              totals[model.presence || "Unknown"] += total_tokens.to_i
            end
            .sort_by { |model, total_tokens| [-total_tokens, model.to_s.downcase] }
      end
    end

    def token_total_for_range(context, date_range:)
      range = prompt_created_at_range(date_range)
      return 0 unless range

      runs_scope(context).where.not(total_tokens: nil).where(created_at: range).sum(:total_tokens).to_i
    end

    def token_change_label(scope, current_range:, previous_range:)
      current = scope.where(created_at: current_range).where.not(total_tokens: nil).sum(:total_tokens)
      previous = scope.where(created_at: previous_range).where.not(total_tokens: nil).sum(:total_tokens)
      percentage_change_label(current: current, previous: previous)
    end

    def weekly_token_series(scope, weeks_back: 12, series_name: "Token usage")
      series_name = Copy.t("common.token_usage") if series_name == "Token usage"
      current_week_start = Time.current.beginning_of_week
      start_week = (current_week_start - (weeks_back - 1).weeks).beginning_of_week
      range = start_week..Time.current
      daily_sums = sums_by_calendar_date(scope.where(created_at: range), :total_tokens)

      [{
        name: series_name,
        data: week_starts(start_week, current_week_start).map do |week_start|
          {
            x: week_start.strftime("%b %-d"),
            y: sum_daily_counts_for_week(daily_sums, week_start)
          }
        end
      }]
    end
  end
end
