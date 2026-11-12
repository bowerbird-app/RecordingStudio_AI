# frozen_string_literal: true

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
      if billing && !configuration.usage_precheck.respond_to?(:call)
        invalid!("usage_handler requires a usage_precheck that responds to call")
      end
      configuration
    end

    def quote(counts:, provider:, model:, prompt: nil, tools: [], configuration: RecordingStudioAI.configuration)
      return nil if configuration.usage_handler.nil?

      book = PriceBook.new(configuration.credit_prices, configuration.credit_price_per)
      positive = positive_counts(counts)
      lines = priced_lines(book, provider, model, positive)
      extras = feature_extras(prompt, tools)
      return nil if positive.empty? && extras.fetch(:fee).zero?

      exact = (lines.sum { |line| line.fetch(:exact) } * extras.fetch(:multiplier)) + extras.fetch(:fee)
      credits = exact.ceil
      credits = 1 if credits.zero?
      Quote.new(
        credits: credits,
        breakdown: breakdown(provider, model, positive, lines, extras, credits)
      )
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

    def positive_counts(counts)
      counts.to_h.each_with_object({}) do |(kind, count), positive|
        next if count.nil? || count.to_i <= 0

        positive[kind.to_sym] = count.to_i
      end
    end

    def priced_lines(book, provider, model, positive)
      positive.map do |kind, count|
        rate = book.rate_for(provider, model, kind)
        exact = rate ? Rational(count * rate.credits, rate.per) : 0
        { kind: kind, count: count, rate: rate, exact: exact }
      end
    end

    def feature_extras(prompt, tools)
      tools = Array(tools)
      prompt_fee = prompt&.credit_fee.to_i
      prompt_multiplier = prompt&.credit_multiplier || 1
      tool_fees = tools.sum { |tool| tool.credit_fee.to_i }
      tool_multiplier = tools.reduce(1) { |product, tool| product * (tool.credit_multiplier || 1) }
      {
        fee: prompt_fee + tool_fees,
        multiplier: prompt_multiplier * tool_multiplier,
        prompt_key: prompt&.key,
        prompt_fee: prompt_fee,
        prompt_multiplier: prompt_multiplier,
        tool_keys: tools.map { |tool| tool.key.to_s }.freeze,
        tool_fee: tool_fees,
        tool_multiplier: tool_multiplier
      }
    end

    def breakdown(provider, model, positive, lines, extras, credits)
      {
        provider: provider.to_s,
        model: model.to_s,
        counts: positive.freeze,
        rates: lines.to_h { |line| [line.fetch(:kind), rate_payload(line[:rate])] }.freeze,
        extras: extras.freeze,
        credits: credits
      }.freeze
    end

    def rate_payload(rate)
      return nil unless rate

      { credits: rate.credits, per: rate.per, source: rate.source }.freeze
    end

    def normalize_prices!(raw, billing:)
      invalid!("credit_prices must be a Hash") unless raw.is_a?(Hash)
      if raw.empty?
        invalid!("credit_prices needs a global \"*\" catch-all when usage_handler is set") if billing
        return {}
      end

      normalized = {}
      raw.each do |key, value|
        if catch_all?(key)
          normalized[CATCH_ALL] = normalize_kinds!(value, "credit_prices[*]")
        else
          provider = key.to_sym
          invalid!("credit_prices[#{provider}] must be a Hash of models") unless value.is_a?(Hash)
          normalized[provider] = normalize_models!(value, provider)
        end
      end
      if billing && !normalized.key?(CATCH_ALL)
        invalid!("credit_prices needs a global \"*\" catch-all when usage_handler is set")
      end
      deep_freeze(normalized)
    end

    def normalize_models!(value, provider)
      value.each_with_object({}) do |(model, kinds), models|
        model_key = catch_all?(model) ? CATCH_ALL : model.to_s
        models[model_key] = normalize_kinds!(kinds, "credit_prices[#{provider}/#{model_key}]")
      end
    end

    def normalize_kinds!(value, path)
      invalid!("#{path} must be a Hash of usage kind prices") unless value.is_a?(Hash)

      value.each_with_object({}) do |(kind, credits), kinds|
        name = kind.to_sym
        invalid!("#{path} #{name} must be a whole number of credits") unless credits.is_a?(Integer) && credits >= 0
        kinds[name] = credits
      end
    end

    def normalize_per!(raw)
      invalid!("credit_price_per must be a Hash") unless raw.is_a?(Hash)

      normalized = raw.each_with_object({}) do |(kind, per), units|
        name = kind.to_sym
        invalid!("credit_price_per #{name} must be a positive whole number") unless per.is_a?(Integer) && per.positive?
        units[name] = per
      end
      normalized.freeze
    end

    def catch_all?(key)
      key.to_s == CATCH_ALL
    end

    def deep_freeze(hash)
      hash.each_value do |value|
        value.each_value(&:freeze) if value.is_a?(Hash)
        value.freeze
      end
      hash.freeze
    end

    def invalid!(message, code = "configuration")
      raise RecordingStudioAI::Errors::ContractValidationError.new(message, code: code)
    end

    class PriceBook
      def initialize(prices, per)
        @prices = prices || {}
        @per = TOKEN_PER.merge(per || {})
      end

      def rate_for(provider, model, kind)
        kind = kind.to_sym
        found = lookup(provider, model, kind)
        return unless found

        credits, source = found
        Rate.new(credits: credits, per: @per.fetch(kind, 1), source: source)
      end

      def catalog_rows
        rows = []
        rows << row("any", "any", @prices.fetch(Credits::CATCH_ALL), nil) if @prices.key?(Credits::CATCH_ALL)
        @prices.each do |provider, models|
          next if provider == Credits::CATCH_ALL
          next unless models.is_a?(Hash)

          rows << row(provider, "any", models.fetch(Credits::CATCH_ALL), nil) if models.key?(Credits::CATCH_ALL)
          models.each do |model, kinds|
            next if model == Credits::CATCH_ALL

            rows << row(provider, model, kinds, nil)
          end
        end
        rows
      end

      def warning_rows(configuration)
        referenced_models(configuration).filter_map do |provider, model|
          next if explicit?(provider, model)

          notice = if provider_catch_all?(provider)
                     :provider
                   elsif @prices.key?(Credits::CATCH_ALL)
                     :global
                   else
                     :none
                   end
          row(provider, model, resolved_kinds(provider, model), notice)
        end
      end

      private

      def lookup(provider, model, kind)
        provider_prices = @prices[provider.to_sym]
        if provider_prices.is_a?(Hash) && provider_prices[model.to_s]&.key?(kind)
          return [provider_prices[model.to_s].fetch(kind), "model"]
        end
        if provider_prices.is_a?(Hash) && provider_prices[Credits::CATCH_ALL]&.key?(kind)
          return [provider_prices[Credits::CATCH_ALL].fetch(kind), "provider"]
        end
        return unless @prices[Credits::CATCH_ALL]&.key?(kind)

        [@prices[Credits::CATCH_ALL].fetch(kind), "global"]
      end

      def explicit?(provider, model)
        prices = @prices[provider.to_sym]
        prices.is_a?(Hash) && prices.key?(model.to_s)
      end

      def provider_catch_all?(provider)
        prices = @prices[provider.to_sym]
        prices.is_a?(Hash) && prices.key?(Credits::CATCH_ALL)
      end

      def resolved_kinds(provider, model)
        kinds = {}
        [*(@prices[Credits::CATCH_ALL] || {}).keys,
         *((@prices[provider.to_sym] || {})[Credits::CATCH_ALL] || {}).keys,
         *((@prices[provider.to_sym] || {})[model.to_s] || {}).keys].uniq.each do |kind|
          rate = rate_for(provider, model, kind)
          kinds[kind] = rate.credits if rate
        end
        kinds
      end

      def referenced_models(configuration)
        models = []
        configuration.profiles.each_value do |entries|
          Array(entries).each { |entry| remember_model(models, entry) }
        end
        configuration.model_fallbacks.each do |key, entries|
          remember_model(models, { provider: key[0], model: key[1] })
          Array(entries).each { |entry| remember_model(models, entry) }
        end
        models.uniq
      end

      def remember_model(models, entry)
        return unless entry.is_a?(Hash)

        provider = entry[:provider] || entry["provider"]
        model = entry[:model] || entry["model"]
        return if provider.nil? || model.nil? || model.to_s.empty?

        models << [provider.to_sym, model.to_s]
      end

      def row(provider, model, kinds, notice)
        {
          provider: provider.to_s,
          model: model.to_s,
          prices: format_prices(kinds),
          notice: notice
        }
      end

      def format_prices(kinds)
        kinds.map do |kind, credits|
          per = @per.fetch(kind.to_sym, 1)
          { kind: kind.to_s, credits: credits, per: per }
        end
      end
    end
  end
end
