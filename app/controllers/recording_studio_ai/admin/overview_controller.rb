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
        latencies = visible_runs.where(created_at: 30.days.ago..).where.not(latency_ms: nil).pluck(:latency_ms).sort
        @p95_latency = latencies[(latencies.length * 0.95).ceil - 1] if latencies.any?
        @daily_activity = (6.days.ago.to_date..Date.current).to_h do |date|
          runs = visible_runs.where(created_at: date.all_day)
          tools = visible_tool_invocations.where(created_at: date.all_day)
          items = RecordingStudioAI::BatchItem.joins(:batch).merge(visible_batches).where(created_at: date.all_day)
          spend, currency = complete_cost(runs)
          [date, {
            runs: runs.count,
            errors: runs.where(status: "failed").count,
            tokens: complete_sum(runs, :total_tokens),
            spend: spend,
            spend_currency: currency,
            tools: tools.count,
            batch_items: items.count
          }]
        end
        currencies = @daily_activity.values.filter_map { |values| values[:spend_currency] }.uniq
        @daily_spend_currency = currencies.first if currencies.one?
        @daily_activity.each_value { |values| values[:spend] = nil } if currencies.many?
      end

      private

      def complete_sum(scope, field)
        values = scope.pluck(field)
        values.empty? || values.any?(&:nil?) ? nil : values.sum
      end

      def complete_cost(scope)
        costs = scope.pluck(:cost_amount_microunits, :cost_currency)
        currencies = costs.map(&:last).uniq
        return [nil, nil] if costs.empty? || costs.any? { |amount, currency| amount.nil? || currency.nil? } || !currencies.one?

        [costs.sum(&:first), currencies.first]
      end
    end
  end
end
