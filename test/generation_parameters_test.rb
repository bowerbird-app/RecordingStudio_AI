# frozen_string_literal: true

require "test_helper"

class GenerationParametersTest < RecordingStudioAI::Test::IsolatedCase
  def setup
    @root_recording = Object.new
    @initiator = Object.new
    stub_host_callbacks!
  end

  def test_validate_generation_request_accepts_stream_model_and_flat_parameters
    request = RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
      root_recording: @root_recording,
      initiator: @initiator,
      prompt: "hello",
      provider: :openai,
      model: "gpt-5-mini",
      stream: true,
      temperature: 0.2,
      verbosity: "low",
      max_output_tokens: 128,
      reasoning_effort: "minimal"
    )

    assert_equal true, request[:stream]
    assert_equal "gpt-5-mini", request[:model]
    assert_in_delta 0.2, request[:temperature]
    assert_equal "low", request[:verbosity]
    assert_equal 128, request[:max_output_tokens]
    assert_equal "minimal", request[:reasoning_effort]
  end

  def test_rejects_unsupported_parameter_for_registered_model
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
        root_recording: @root_recording,
        initiator: @initiator,
        prompt: "hello",
        provider: :gemini,
        model: "gemini-2.5-flash",
        verbosity: "high"
      )
    end

    assert_match(/verbosity is not supported/, error.message)
  end

  def test_generate_rejects_block_without_stream
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "hello",
        root_recording: @root_recording,
        initiator: @initiator
      ) { |_event| }
    end

    assert_match(/stream: true/, error.message)
  end

  def test_resolver_pins_model_override
    configuration = RecordingStudioAI::Configuration.new
    configuration.providers = {
      openai: Class.new(RecordingStudioAI::Providers::Base) do
        def configured? = true
      end.new,
      gemini: Class.new(RecordingStudioAI::Providers::Base) do
        def configured? = true
      end.new
    }
    configuration.profiles[:medium] = [
      { provider: :openai, model: "gpt-5-mini" },
      { provider: :gemini, model: "gemini-2.5-flash" }
    ]
    resolver = RecordingStudioAI::Resolver.new(configuration: configuration)

    candidate = resolver.resolve(
      profile: :medium,
      required_capabilities: [:generation],
      model: "gemini-2.5-flash"
    )

    assert_equal :gemini, candidate.provider
    assert_equal "gemini-2.5-flash", candidate.model
  end

  def test_adapt_for_model_keeps_supported_overrides_and_omits_unsupported
    gpt = RecordingStudioAI.models.fetch(:openai, "gpt-5-mini")
    flash = RecordingStudioAI.models.fetch(:gemini, "gemini-2.5-flash")
    overrides = { temperature: 0.3, verbosity: "high", max_output_tokens: 128 }

    adapted_gpt = RecordingStudioAI::Models::ParameterValidation.adapt_for_model(gpt, overrides)
    adapted_flash = RecordingStudioAI::Models::ParameterValidation.adapt_for_model(flash, overrides)

    assert_in_delta 0.3, adapted_gpt[:temperature]
    assert_equal "high", adapted_gpt[:verbosity]
    assert_equal 128, adapted_gpt[:max_output_tokens]

    assert_in_delta 0.3, adapted_flash[:temperature]
    assert_nil adapted_flash[:verbosity]
    assert_equal 128, adapted_flash[:max_output_tokens]
  end

  def test_adapt_for_model_clamps_numeric_overrides_to_the_candidate_range
    flash = RecordingStudioAI.models.fetch(:gemini, "gemini-2.5-flash")
    adapted = RecordingStudioAI::Models::ParameterValidation.adapt_for_model(
      flash,
      temperature: 2.5,
      max_output_tokens: 128
    )

    assert_in_delta 2.0, adapted[:temperature]
    assert_equal 128, adapted[:max_output_tokens]
  end

  def test_adapt_for_model_omits_enum_values_the_candidate_does_not_allow
    gpt = RecordingStudioAI.models.fetch(:openai, "gpt-5-mini")
    adapted = RecordingStudioAI::Models::ParameterValidation.adapt_for_model(
      gpt,
      reasoning_effort: "ludicrous"
    )

    assert_nil adapted[:reasoning_effort]
  end

  def test_normalize_still_raises_for_unsupported_parameter_on_pinned_model
    flash = RecordingStudioAI.models.fetch(:gemini, "gemini-2.5-flash")

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Models::ParameterValidation.normalize!(flash, verbosity: "high")
    end

    assert_match(/verbosity is not supported/, error.message)
  end
end
