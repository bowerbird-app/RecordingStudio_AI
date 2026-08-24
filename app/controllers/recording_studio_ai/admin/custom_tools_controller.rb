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

    end
  end
end
