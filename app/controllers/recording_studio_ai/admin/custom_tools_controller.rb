# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class CustomToolsController < ApplicationController
      def index
        @definitions = RecordingStudioAI.tools.all
        @today_counts = visible_tool_invocations.where(created_at: Time.current.beginning_of_day..).group(:tool_key, :tool_version).count
        @thirty_day_counts = visible_tool_invocations.where(created_at: 30.days.ago..).group(:tool_key, :tool_version).count
        outcome_counts = visible_tool_invocations.where(created_at: 30.days.ago..).group(:tool_key, :tool_version, :status).count
        outcome_totals = outcome_counts.each_with_object(Hash.new(0)) do |((tool_key, version, _), count), totals|
          totals[[tool_key, version]] += count
        end
        @outcomes = outcome_counts.each_with_object({}) do |(key, count), rates|
          rates[key] = count.to_f / outcome_totals.fetch(key.first(2))
        end
        @average_latency = visible_tool_invocations.where(created_at: 30.days.ago..).group(:tool_key, :tool_version).average(:latency_ms)
        @p95_latency = visible_tool_invocations.where(created_at: 30.days.ago..).where.not(latency_ms: nil)
          .pluck(:tool_key, :tool_version, :latency_ms)
          .group_by { |tool_key, version, _| [tool_key, version] }
          .transform_values do |values|
            latencies = values.map(&:last).sort
            latencies[(latencies.length * 0.95).ceil - 1]
          end
      end

      def show
        @definition = RecordingStudioAI.tools.fetch(params[:key], version: params[:version].to_i)
        raise ActiveRecord::RecordNotFound, "custom tool is not registered" unless @definition

        @invocations = visible_tool_invocations
          .where(tool_key: @definition.key, tool_version: @definition.version)
          .includes(:run)
          .order(created_at: :desc)
          .limit(100)
        @sensitive_roots = @admin_access.root_ids.index_with do |root_id|
          @admin_access.allowed?(:view_sensitive_execution, root_id: root_id, context: { custom_tool: @definition.key })
        end
        @outcomes = @invocations.group_by(&:status).transform_values(&:count)
        @argument_digests = @invocations
          .select { |invocation| @sensitive_roots[invocation.run.root_recording_id] }
          .filter_map(&:arguments_digest)
          .tally
          .sort_by { |_, count| -count }
          .first(10)
        @calls_per_run = @invocations.group_by(&:run_id).transform_values(&:count).sort_by { |_, count| -count }.first(10)
        @common_errors = @invocations.filter_map do |invocation|
          [invocation.error_category, invocation.error_code] if invocation.error_category.present? || invocation.error_code.present?
        end.tally.sort_by { |_, count| -count }.first(10)
        @daily_usage = (6.days.ago.to_date..Date.current).to_h do |date|
          [date, @invocations.count { |invocation| invocation.created_at.to_date == date }]
        end
      end
    end
  end
end
