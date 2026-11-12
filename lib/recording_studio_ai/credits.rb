# frozen_string_literal: true

require "recording_studio_ai/credits/normalizer"
require "recording_studio_ai/credits/extras"
require "recording_studio_ai/credits/price_book"

module RecordingStudioAI
  module Credits
    CATCH_ALL = "*"
    TOKEN_PER = {
      input: 1_000_000,
      output: 1_000_000,
      cached_input: 1_000_000,
      reasoning: 1_000_000
    }.freeze

    Rate = Data.define(:credits, :per, :source)
    Quote = Data.define(:credits, :breakdown)

    module_function

    def normalize_configuration!(configuration)
      billing = !configuration.usage_handler.nil?
      configuration.credit_prices = normalize_prices!(configuration.credit_prices, billing: billing)
      configuration.credit_price_per = normalize_per!(configuration.credit_price_per)
      return configuration unless missing_precheck?(billing, configuration)

      invalid!("usage_handler requires a usage_precheck that responds to call")
    end

    def quote(counts:, provider:, model:, **options)
      configuration = options.fetch(:configuration) { RecordingStudioAI.configuration }
      return nil if configuration.usage_handler.nil?

      assembled = assemble_quote(counts, provider, model, options, configuration)
      assembled && Quote.new(**assembled)
    end

    def price_rows(configuration)
      book = PriceBook.new(
        normalize_prices!(configuration.credit_prices || {}, billing: false),
        normalize_per!(configuration.credit_price_per || {})
      )
      book.catalog_rows + book.warning_rows(configuration)
    end

    def normalize_fee(value, label, code: "configuration")
      number = value.nil? ? 0 : value
      return number if number.is_a?(Integer) && number >= 0

      invalid!("#{label} must be a whole number of credits or blank", code)
    end

    def normalize_multiplier(value, label, code: "configuration")
      number = value.nil? ? 1 : value
      return number if number.is_a?(Integer) && number.positive?

      invalid!("#{label} must be a positive whole number or blank", code)
    end

    def assemble_quote(counts, provider, model, options, configuration)
      book = PriceBook.new(configuration.credit_prices, configuration.credit_price_per)
      positive = positive_counts(counts)
      lines = priced_lines(book, provider, model, positive)
      extras = feature_extras(options[:prompt], options[:tools])
      return if positive.empty? && extras.fetch(:fee).zero?

      credits = whole_credits(lines, extras)
      scope = { provider: provider, model: model, positive: positive }
      { credits: credits, breakdown: freeze_breakdown(scope, lines, extras, credits) }
    end

    def whole_credits(lines, extras)
      exact = (lines.sum { |line| line.fetch(:exact) } * extras.fetch(:multiplier)) + extras.fetch(:fee)
      [exact.ceil, 1].max
    end

    def positive_counts(counts)
      counts.to_h.each_with_object({}) do |(kind, count), positive|
        next if count.nil? || count.to_i <= 0

        positive[kind.to_sym] = count.to_i
      end
    end

    def priced_lines(book, provider, model, positive)
      positive.map do |kind, count|
        rate = book.rate_for(provider, model, kind)
        { kind: kind, count: count, rate: rate, exact: rate ? Rational(count * rate.credits, rate.per) : 0 }
      end
    end

    def freeze_breakdown(scope, lines, extras, credits)
      {
        provider: scope.fetch(:provider).to_s,
        model: scope.fetch(:model).to_s,
        counts: scope.fetch(:positive).freeze,
        rates: lines.to_h { |line| [line.fetch(:kind), rate_payload(line[:rate])] }.freeze,
        extras: extras.freeze,
        credits: credits
      }.freeze
    end

    def rate_payload(rate)
      return nil unless rate

      { credits: rate.credits, per: rate.per, source: rate.source }.freeze
    end

    def missing_precheck?(billing, configuration)
      billing && !configuration.usage_precheck.respond_to?(:call)
    end

    def invalid!(message, code = "configuration")
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: code)
    end

    private_class_method :assemble_quote, :whole_credits, :positive_counts, :priced_lines,
                         :freeze_breakdown, :rate_payload, :missing_precheck?, :invalid!
  end
end
