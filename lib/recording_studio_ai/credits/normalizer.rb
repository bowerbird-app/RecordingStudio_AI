# frozen_string_literal: true

module RecordingStudioAI
  module Credits
    module_function

    def normalize_prices!(raw, billing:)
      invalid!("credit_prices must be a Hash") unless raw.is_a?(Hash)
      return empty_prices(billing) if raw.empty?

      normalized = raw.each_with_object({}) { |pair, prices| store_price!(prices, pair) }
      require_global_catch_all!(normalized) if billing
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

      raw.each_with_object({}) do |(kind, per), units|
        name = kind.to_sym
        invalid!("credit_price_per #{name} must be a positive whole number") unless per.is_a?(Integer) && per.positive?
        units[name] = per
      end.freeze
    end

    def empty_prices(billing)
      invalid!(catch_all_message) if billing
      {}
    end

    def store_price!(prices, pair)
      key, value = pair
      if catch_all?(key)
        prices[CATCH_ALL] = normalize_kinds!(value, "credit_prices[*]")
      else
        store_provider!(prices, key, value)
      end
    end

    def store_provider!(prices, key, value)
      provider = key.to_sym
      invalid!("credit_prices[#{provider}] must be a Hash of models") unless value.is_a?(Hash)
      prices[provider] = normalize_models!(value, provider)
    end

    def require_global_catch_all!(normalized)
      return if normalized.key?(CATCH_ALL)

      invalid!(catch_all_message)
    end

    def catch_all_message
      "credit_prices needs a global \"*\" catch-all when usage_handler is set"
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

    private_class_method :empty_prices, :store_price!, :store_provider!, :require_global_catch_all!,
                         :catch_all_message, :catch_all?, :deep_freeze
  end
end
