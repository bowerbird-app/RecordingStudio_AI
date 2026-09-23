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
      parameters: { temperature: { type: :number, min: 0.0, max: 2.0, default: 1.0, step: 0.1 } },
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

  def test_omitted_operations_still_mean_generation
    definition = @registry.register(provider: :openai, key: "text-only", model: "text-only")

    assert_equal [:generation], definition.operations
    assert_empty definition.decision_types
  end

  def test_generation_only_model_declares_no_decision_capabilities
    definition = @registry.register(
      provider: :openai,
      key: "gpt-5",
      model: "gpt-5",
      operations: [:generation],
      delivery: { streaming: true, structured_output: true }
    )

    assert_equal %i[generation streaming structured_output], definition.capabilities
  end

  def test_decision_only_model_declares_operation_and_question_kinds_only
    definition = @registry.register(
      provider: :typesafe,
      key: "jev-latest",
      model: "jev-latest",
      operations: [:decision],
      decision_types: %i[choice score noul],
      modalities: { input: [:text], output: [] }
    )

    assert_equal [:decision], definition.operations
    assert_equal %i[choice score noul], definition.decision_types
    assert_equal %i[decision decision_choice decision_score decision_noul], definition.capabilities
    refute_includes definition.capabilities, :generation
  end

  def test_decision_model_may_declare_a_single_question_kind
    definition = @registry.register(
      provider: :typesafe,
      key: "jev-noul",
      model: "jev-noul",
      operations: [:decision],
      decision_types: [:noul]
    )

    assert_equal %i[decision decision_noul], definition.capabilities
  end

  def test_unknown_operation_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", operations: %i[generation divination])
    end
    assert_match(/unknown model operations: divination/, error.message)
  end

  def test_empty_operations_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", operations: [])
    end
    assert_match(/model operations must not be empty/, error.message)
  end

  def test_decision_operation_requires_decision_types
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :typesafe, key: "jev-latest", model: "jev-latest", operations: [:decision])
    end
    assert_match(/decision_types is required when operations include :decision/, error.message)
  end

  def test_decision_types_require_the_decision_operation
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :openai, key: "gpt-5", model: "gpt-5", decision_types: [:choice])
    end
    assert_match(/decision_types requires operations to include :decision/, error.message)
  end

  def test_unknown_decision_type_raises
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(provider: :typesafe, key: "jev-latest", model: "jev-latest",
                         operations: [:decision], decision_types: %i[choice vibes])
    end
    assert_match(/unknown decision types: vibes/, error.message)
  end

  def test_generation_delivery_flags_require_the_generation_operation
    %i[streaming structured_output batch batch_cancellation].each do |flag|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        @registry.register(provider: :typesafe, key: "jev-latest", model: "jev-latest",
                           operations: [:decision], decision_types: [:noul], delivery: { flag => true })
      end
      assert_match(/delivery #{flag} requires operations to include :generation/, error.message)
    end
  end

  def test_builtin_jev_is_registered_as_a_decision_only_model
    definition = RecordingStudioAI.models.fetch(:typesafe, "jev-latest")

    assert_equal "Jev", definition.display_name
    assert_equal [:decision], definition.operations
    assert_equal %i[choice score noul], definition.decision_types
    assert_equal %i[decision decision_choice decision_score decision_noul], definition.capabilities
    assert_empty definition.parameters
    assert_empty definition.tools
    assert_equal [:text], definition.modalities[:input]
  end

  def test_builtin_generation_models_declare_the_generation_operation_only
    [[:openai, "gpt-5-mini"], [:openai, "gpt-5"], [:openai, "gpt-5-pro"],
     [:gemini, "gemini-2.5-flash"], [:gemini, "gemini-2.5-pro"]].each do |provider, model|
      definition = RecordingStudioAI.models.fetch(provider, model)

      assert_equal [:generation], definition.operations, "#{provider}/#{model} operations"
      assert_empty definition.decision_types, "#{provider}/#{model} decision_types"
      refute_includes definition.capabilities, :decision, "#{provider}/#{model} capabilities"
    end
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
                         parameters: { top_p: { type: :number } })
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
    assert registry.fetch(:typesafe, "jev-latest")
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
        temperature: { type: :number, min: 0.0, max: 2.0, default: 1.0 }
      },
      tools: %i[web_search]
    )

    assert definition.supports_parameter?(:temperature)
    refute definition.supports_parameter?(:verbosity)
    refute definition.supports_parameter?(:reasoning_effort)
    assert definition.supports_tool?(:web_search)
    refute definition.supports_tool?(:code_execution)
    assert_equal :number, definition.parameter(:temperature)[:type]
    assert_equal 2.0, definition.parameter(:temperature)[:max]
  end

  def test_parameter_requires_type_and_rejects_supported_flag
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(
        provider: :openai,
        key: "gpt-5",
        model: "gpt-5",
        parameters: { temperature: { min: 0.0, max: 2.0 } }
      )
    end
    assert_match(/requires type:/, error.message)

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @registry.register(
        provider: :openai,
        key: "gpt-5",
        model: "gpt-5",
        parameters: { temperature: { supported: true, type: :number } }
      )
    end
    assert_match(/no longer accepts supported:/, error.message)
  end
end
