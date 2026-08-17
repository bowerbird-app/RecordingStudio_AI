# frozen_string_literal: true

require "test_helper"

class ModelsRegistryTest < Minitest::Test
  def setup
    @registry = RecordingStudioAI::Models::Registry.new
  end

  def test_registers_and_fetches_by_key_and_model
    definition = @registry.register(
      provider: :openai,
      key: "gpt-5",
      model: "gpt-5",
      display_name: "GPT-5",
      delivery: { streaming: true, structured_output: true, batch: true, batch_cancellation: true },
      parameters: { temperature: { supported: true, min: 0.0, max: 2.0, default: 1.0, step: 0.1 } },
      tools: %i[web_search custom_tools],
      modalities: { input: %i[text image file], output: %i[text] }
    )

    assert_equal :openai, definition.provider
    assert_equal "gpt-5", definition.key
    assert_equal definition, @registry.fetch(:openai, "gpt-5")
    assert_equal definition, @registry.fetch_by_key(:openai, "gpt-5")
    assert @registry.registered?(:openai, "gpt-5")
  end

  def test_fetches_by_model_string_when_key_differs
    definition = @registry.register(
      provider: :gemini,
      key: "gemini-2-5-pro",
      model: "gemini-2.5-pro",
      modalities: { input: %i[text], output: %i[text] }
    )

    assert_equal definition, @registry.fetch(:gemini, "gemini-2.5-pro")
    assert_equal definition, @registry.fetch_by_key(:gemini, "gemini-2-5-pro")
  end

  def test_derives_capabilities_from_delivery_tools_and_modalities
    definition = @registry.register(
      provider: :openai,
      key: "gpt-5",
      model: "gpt-5",
      delivery: { streaming: true, structured_output: true, batch: true, batch_cancellation: true },
      tools: %i[web_search custom_tools],
      modalities: { input: %i[text image file], output: %i[text] }
    )

    assert_equal(
      %i[generation streaming structured_output provider_batch provider_batch_cancellation image_input file_input
         provider_native_web_search custom_tools].sort,
      definition.capabilities.sort
    )
  end

  def test_minimal_model_only_supports_generation
    definition = @registry.register(provider: :openai, key: "text-only", model: "text-only")

    assert_equal [:generation], definition.capabilities
    refute definition.delivery[:streaming]
    assert_empty definition.tools
  end

  def test_duplicate_registration_raises_without_override
    @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5")

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5")
    end
    assert_match(/already registered/, error.message)
  end

  def test_override_replaces_existing_registration
    @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", display_name: "First")
    definition = @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", display_name: "Second",
                                    override: true)

    assert_equal "Second", definition.display_name
    assert_equal 1, @registry.for_provider(:openai).size
  end

  def test_invalid_key_format_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "GPT_5", model: "gpt-5")
    end
    assert_match(/lowercase hyphenated slug/, error.message)
  end

  def test_unknown_parameter_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5",
                         parameters: { top_p: { supported: true } })
    end
    assert_match(/unknown model parameter/, error.message)
  end

  def test_unknown_tool_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", tools: %i[telepathy])
    end
    assert_match(/unknown model tools/, error.message)
  end

  def test_unknown_modality_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5",
                         modalities: { input: %i[hologram] })
    end
    assert_match(/unknown modalities/, error.message)
  end

  def test_builtin_models_are_registered_for_default_profiles
    registry = RecordingStudioAI.models

    assert registry.fetch(:openai, "gpt-5-mini")
    assert registry.fetch(:openai, "gpt-5")
    assert registry.fetch(:openai, "gpt-5-pro")
    assert registry.fetch(:gemini, "gemini-2.5-flash")
    assert registry.fetch(:gemini, "gemini-2.5-pro")
  end

  def test_resolver_derives_capabilities_from_registry_when_profile_omits_them
    configuration = RecordingStudioAI::Configuration.new
    configuration.openai_api_key = "test-key"
    configuration.profiles = {
      medium: [{ provider: :openai, model: "gpt-5" }]
    }

    candidate = RecordingStudioAI::Resolver.new(configuration: configuration).resolve(
      profile: :medium,
      required_capabilities: %i[generation streaming structured_output]
    )

    assert_equal :openai, candidate.provider
    assert_equal "gpt-5", candidate.model
    assert_includes candidate.capabilities, :streaming
    assert_includes candidate.capabilities, :structured_output
  end

  def test_resolver_still_honors_explicit_capabilities_on_profile_entries
    configuration = RecordingStudioAI::Configuration.new
    configuration.openai_api_key = "test-key"
    configuration.profiles = {
      medium: [{ provider: :openai, model: "custom-unregistered", capabilities: %i[generation] }]
    }

    candidate = RecordingStudioAI::Resolver.new(configuration: configuration).resolve(
      profile: :medium,
      required_capabilities: %i[generation]
    )

    assert_equal "custom-unregistered", candidate.model
    assert_equal %i[generation], candidate.capabilities
  end

  def test_parameter_helpers
    definition = @registry.register(
      provider: :openai,
      key: "gpt-5",
      model: "gpt-5",
      parameters: {
        temperature: { supported: true, min: 0.0, max: 2.0, default: 1.0 },
        verbosity: { supported: false, values: %w[low medium high] }
      },
      tools: %i[web_search]
    )

    assert definition.supports_parameter?(:temperature)
    refute definition.supports_parameter?(:verbosity)
    refute definition.supports_parameter?(:reasoning_effort)
    assert definition.supports_tool?(:web_search)
    refute definition.supports_tool?(:code_execution)
    assert_equal 2.0, definition.parameter(:temperature)[:max]
  end
end
