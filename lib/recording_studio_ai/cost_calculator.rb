# frozen_string_literal: true

module RecordingStudioAI
  module CostCalculator
    RATE_FIELDS = %i[input_tokens output_tokens cached_input_tokens reasoning_tokens].freeze
    SCALE = 1_000_000

    module_function

    def apply(result, provider:, model:, configuration: RecordingStudioAI.configuration)
      return result if result.cost

      cost = estimate(result.usage, provider: provider, model: model, configuration: configuration)
      cost ? result.with(cost: cost) : result
    end

    def estimate(usage, provider:, model:, configuration: RecordingStudioAI.configuration)
      rates = configuration.cost_catalogs.dig(provider.to_sym, model.to_s)
      return unless usage && rates

      rates = rates.transform_keys(&:to_sym)
      configured_fields = RATE_FIELDS.select { |field| rates.key?(field) }
      return if configured_fields.empty? || configured_fields.any? { |field| usage.public_send(field).nil? }

      amount = configured_fields.sum do |field|
        Rational(usage.public_send(field) * rates.fetch(field), SCALE)
      end.round
      Contracts::Cost.new(
        amount: amount,
        currency: rates.fetch(:currency, "USD").to_s,
        estimated: true,
        source: "catalog"
      )
    end
  end
end