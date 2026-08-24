# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class OverviewController < ApplicationController
      def show
        now = Time.current
        @run_counts = {
          today: visible_runs.where(created_at: now.beginning_of_day..).count,
          seven_days: visible_runs.where(created_at: 7.days.ago..).count,
          thirty_days: visible_runs.where(created_at: 30.days.ago..).count
        }
        @metrics = RecordingStudioAI::WarningMetrics.new(root_ids: @admin_access.root_ids).call
        @attempt_count = visible_attempts.where(created_at: 24.hours.ago..).count
        @tool_count = visible_tool_invocations.where(created_at: 24.hours.ago..).count
        @web_search_count = visible_runs.where(created_at: 24.hours.ago.., web_search_used: true).count
        @batch_count = visible_batches.where(created_at: 24.hours.ago..).count
        @batch_item_count = RecordingStudioAI::BatchItem.joins(:batch).merge(visible_batches).where(created_at: 24.hours.ago..).count
        @outcomes = visible_runs.where(created_at: 30.days.ago..).group(:status).count
        @providers = visible_runs.where(created_at: 30.days.ago..).group(:resolved_provider).count
        @models = visible_runs.where(created_at: 30.days.ago..).group(:resolved_model).count
        @profiles = visible_runs.where(created_at: 30.days.ago..).group(:profile_key).count
        @operations = visible_runs.where(created_at: 30.days.ago..).group(:operation).count
        @purposes = visible_runs.where(created_at: 30.days.ago..).group(:purpose).count
        @roots = visible_runs.where(created_at: 30.days.ago..).group(:root_recording_id).count
        @initiators = visible_runs.where(created_at: 30.days.ago..).group(:initiator_type, :initiator_kind).count
        @executors = visible_runs.where(created_at: 30.days.ago..).group(:executor_type, :executor_kind).count
        @sources = visible_runs.where(created_at: 30.days.ago..).group(:execution_source).count
        @errors = visible_runs.where(created_at: 30.days.ago..).where.not(error_category: nil).group(:error_category).count
        @tool_keys = visible_tool_invocations.where(created_at: 30.days.ago..).group(:tool_key).count
        @slow_runs = visible_runs.where.not(latency_ms: nil).order(latency_ms: :desc).limit(10)
        @p95_latency = percentile_latency_ms(visible_runs.where(created_at: 30.days.ago..).where.not(latency_ms: nil), 0.95)
        @daily_activity = daily_activity_window
      end

      private

      def daily_activity_window
        dates = (6.days.ago.to_date..Date.current).to_a
        range = dates.first.beginning_of_day..dates.last.end_of_day
        run_date = Arel.sql("DATE(#{RecordingStudioAI::Run.table_name}.created_at)")
        tool_date = Arel.sql("DATE(#{RecordingStudioAI::CustomToolInvocation.table_name}.created_at)")
        item_date = Arel.sql("DATE(#{RecordingStudioAI::BatchItem.table_name}.created_at)")

        window_runs = visible_runs.where(created_at: range)
        runs_by_date = group_counts_by_date(window_runs, run_date)
        errors_by_date = group_counts_by_date(window_runs.where(status: "failed"), run_date)
        tokens_by_date = complete_sum_by_date(window_runs, :total_tokens, run_date)
        tools_by_date = group_counts_by_date(
          visible_tool_invocations.where(created_at: range),
          tool_date
        )
        items_by_date = group_counts_by_date(
          RecordingStudioAI::BatchItem.joins(:batch).merge(visible_batches).where(created_at: range),
          item_date
        )

        dates.index_with do |date|
          {
            runs: runs_by_date.fetch(date, 0),
            errors: errors_by_date.fetch(date, 0),
            tokens: tokens_by_date.fetch(date, nil),
            tools: tools_by_date.fetch(date, 0),
            batch_items: items_by_date.fetch(date, 0)
          }
        end
      end

      def group_counts_by_date(scope, date_sql)
        scope.group(date_sql).count.transform_keys { |key| normalize_sql_date(key) }
      end

      def complete_sum_by_date(scope, field, date_sql)
        counts = scope.group(date_sql).count
        null_counts = scope.where(field => nil).group(date_sql).count
        sums = scope.group(date_sql).sum(field)

        counts.each_with_object({}) do |(key, count), memo|
          date = normalize_sql_date(key)
          memo[date] =
            if count.to_i.zero? || null_counts.fetch(key, 0).positive?
              nil
            else
              sums.fetch(key, 0).to_i
            end
        end
      end

      def normalize_sql_date(value)
        case value
        when Date then value
        when Time, DateTime, ActiveSupport::TimeWithZone then value.to_date
        else Date.parse(value.to_s)
        end
      end

      def percentile_latency_ms(scope, percentile)
        count = scope.count
        return if count.zero?

        offset = [(count * percentile).ceil - 1, 0].max
        scope.order(:latency_ms).offset(offset).limit(1).pick(:latency_ms)
      end
    end
  end
end
