# frozen_string_literal: true

require "test_helper"

class CreditQuoteTest < Minitest::Test
  def setup
    @configuration = RecordingStudioAI::Configuration.new
    @configuration.usage_handler = ->(**) {}
    @configuration.usage_precheck = ->(**) { true }
    @configuration.credit_prices = {
      "*" => { input: 100, output: 400, web_search: 5, decision: 2 },
      openai: {
        "*" => { input: 200 },
        "gpt-exact" => { output: 50 }
      }
    }
    @configuration.validate!
  end

  def test_lookup_prefers_the_model_then_the_provider_then_the_global_price
    quote = quote_for({ input: 1_000_000, output: 1_000_000, web_search: 1 }, provider: :openai, model: "gpt-exact")

    assert_equal "model", quote.breakdown.dig(:rates, :output, :source)
    assert_equal 50, quote.breakdown.dig(:rates, :output, :credits)
    assert_equal "provider", quote.breakdown.dig(:rates, :input, :source)
    assert_equal 200, quote.breakdown.dig(:rates, :input, :credits)
    assert_equal "global", quote.breakdown.dig(:rates, :web_search, :source)
    assert_equal 255, quote.credits
  end

  def test_an_unknown_model_uses_the_provider_catch_all
    quote = quote_for({ input: 1_000_000 }, provider: :openai, model: "gpt-other")

    assert_equal "provider", quote.breakdown.dig(:rates, :input, :source)
    assert_equal 200, quote.credits
  end

  def test_a_new_provider_uses_the_global_catch_all
    quote = quote_for({ output: 1_000_000 }, provider: :gemini, model: "gemini-new")

    assert_equal "global", quote.breakdown.dig(:rates, :output, :source)
    assert_equal 400, quote.credits
  end

  def test_fractional_kinds_round_up_once
    @configuration.credit_prices = { "*" => { input: 400_000, output: 400_000 } }
    @configuration.validate!
    quote = quote_for({ input: 1, output: 1 }, provider: :openai, model: "gpt-exact")

    assert_equal 1, quote.credits
  end

  def test_any_reported_usage_costs_at_least_one_credit
    @configuration.credit_prices = { "*" => { input: 0 } }
    @configuration.validate!
    quote = quote_for({ input: 3 }, provider: :openai, model: "gpt-exact")

    assert_equal 1, quote.credits
  end

  def test_no_usage_and_no_fee_does_not_quote
    assert_nil quote_for({}, provider: :openai, model: "gpt-exact")
  end

  def test_a_future_kind_is_priced_from_config_without_a_new_token_field
    @configuration.credit_prices = { "*" => { audio_seconds: 3 } }
    @configuration.credit_price_per = { audio_seconds: 1 }
    @configuration.validate!
    quote = quote_for({ audio_seconds: 2 }, provider: :openai, model: "gpt-exact")

    assert_equal 6, quote.credits
    assert_equal 1, quote.breakdown.dig(:rates, :audio_seconds, :per)
  end

  def test_real_money_catalogs_do_not_change_the_credit_quote
    @configuration.cost_catalogs = { openai: { "gpt-exact" => { input_tokens: 9_999, currency: "USD" } } }
    quote = quote_for({ input: 1_000_000 }, provider: :openai, model: "gpt-exact")

    assert_equal 200, quote.credits
  end

  def test_price_rows_list_catch_alls_and_warn_about_unpriced_profile_models
    @configuration.profiles = { medium: [{ provider: :openai, model: "gpt-unpriced" }] }
    @configuration.model_fallbacks = {}
    rows = RecordingStudioAI::Credits.price_rows(@configuration)
    global = rows.find { |row| row[:provider] == "any" && row[:model] == "any" }
    exact = rows.find { |row| row[:model] == "gpt-exact" }
    warning = rows.find { |row| row[:model] == "gpt-unpriced" }

    assert_equal "input", global[:prices].first[:kind]
    assert_equal 50, exact[:prices].find { |price| price[:kind] == "output" }[:credits]
    assert_equal :provider, warning[:notice]
  end

  def test_no_handler_does_not_quote_or_require_prices
    bare = RecordingStudioAI::Configuration.new

    assert_nil RecordingStudioAI::Credits.quote(
      counts: { input: 10 }, provider: :openai, model: "gpt-exact", configuration: bare
    )
    assert_same bare, bare.validate!
  end

  private

  def quote_for(counts, provider:, model:)
    RecordingStudioAI::Credits.quote(
      counts: counts, provider: provider, model: model, configuration: @configuration
    )
  end
end
