# frozen_string_literal: true

module RecordingStudioAI
  module Admin
    class ProviderNativeToolsController < ApplicationController
      def show
        web_search_runs = visible_runs.where(web_search_requested: true)
        @runs = web_search_runs.order(created_at: :desc).limit(100)
        @attempts = visible_attempts.where(web_search_requested: true)
        @providers = @attempts.group(:provider).count
        @models = @attempts.group(:model).count
        @outcomes = web_search_runs.group(:status).count
        @citation_count = web_search_runs.sum(:citation_count)
        @average_latency = web_search_runs.average(:latency_ms)&.to_f
        @cost_microunits, @cost_currency = complete_cost(web_search_runs)
      end

      private

      def complete_cost(scope)
        costs = scope.pluck(:cost_amount_microunits, :cost_currency)
        currencies = costs.map(&:last).uniq
        return [nil, nil] if costs.empty? || costs.any? { |amount, currency| amount.nil? || currency.nil? } || !currencies.one?

        [costs.sum(&:first), currencies.first]
      end
    end
  end
end
