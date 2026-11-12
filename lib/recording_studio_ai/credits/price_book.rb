# frozen_string_literal: true

module RecordingStudioAI
  module Credits
    module ReferencedModels
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
    end

    class PriceBook
      include ReferencedModels

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
        append_global(rows)
        @prices.each { |provider, models| append_provider(rows, provider, models) }
        rows
      end

      def warning_rows(configuration)
        referenced_models(configuration).filter_map { |provider, model| warning_row(provider, model) }
      end

      private

      def lookup(provider, model, kind)
        tier(provider, model.to_s, kind, "model") ||
          tier(provider, CATCH_ALL, kind, "provider") ||
          global_tier(kind)
      end

      def tier(provider, model, kind, source)
        prices = @prices[provider.to_sym]
        return unless prices.is_a?(Hash) && prices[model]&.key?(kind)

        [prices[model].fetch(kind), source]
      end

      def global_tier(kind)
        prices = @prices[CATCH_ALL]
        return unless prices&.key?(kind)

        [prices.fetch(kind), "global"]
      end

      def append_global(rows)
        return unless @prices.key?(CATCH_ALL)

        rows << row("any", "any", @prices.fetch(CATCH_ALL), nil)
      end

      def append_provider(rows, provider, models)
        return if provider == CATCH_ALL || !models.is_a?(Hash)

        rows << row(provider, "any", models.fetch(CATCH_ALL), nil) if models.key?(CATCH_ALL)
        append_models(rows, provider, models)
      end

      def append_models(rows, provider, models)
        models.each do |model, kinds|
          next if model == CATCH_ALL

          rows << row(provider, model, kinds, nil)
        end
      end

      def warning_row(provider, model)
        return if explicit?(provider, model)

        row(provider, model, resolved_kinds(provider, model), notice_for(provider))
      end

      def notice_for(provider)
        return :provider if provider_catch_all?(provider)
        return :global if @prices.key?(CATCH_ALL)

        :none
      end

      def explicit?(provider, model)
        prices = @prices[provider.to_sym]
        prices.is_a?(Hash) && prices.key?(model.to_s)
      end

      def provider_catch_all?(provider)
        prices = @prices[provider.to_sym]
        prices.is_a?(Hash) && prices.key?(CATCH_ALL)
      end

      def resolved_kinds(provider, model)
        kind_names(provider, model).each_with_object({}) do |kind, kinds|
          rate = rate_for(provider, model, kind)
          kinds[kind] = rate.credits if rate
        end
      end

      def kind_names(provider, model)
        provider_prices = @prices[provider.to_sym] || {}
        [
          *(@prices[CATCH_ALL] || {}).keys,
          *(provider_prices[CATCH_ALL] || {}).keys,
          *(provider_prices[model.to_s] || {}).keys
        ].uniq
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
          { kind: kind.to_s, credits: credits, per: @per.fetch(kind.to_sym, 1) }
        end
      end
    end
  end
end
