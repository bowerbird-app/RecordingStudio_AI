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

  def test_validate_accepts_explicit_fallbacks_list
    request = RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
      root_recording: @root_recording,
      initiator: @initiator,
      prompt: "hello",
      fallbacks: [
        { provider: :openai, model: "gpt-5-mini" },
        { provider: :gemini, model: "gemini-2.5-flash" }
      ],
      temperature: 1.0
    )

    assert_equal [
      { provider: :openai, model: "gpt-5-mini" },
      { provider: :gemini, model: "gemini-2.5-flash" }
    ], request[:fallbacks]
    assert_in_delta 1.0, request[:temperature]
  end

  def test_validate_rejects_fallbacks_combined_with_model
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
        root_recording: @root_recording,
        initiator: @initiator,
        prompt: "hello",
        model: "gpt-5-mini",
        fallbacks: [{ provider: :openai, model: "gpt-5-mini" }]
      )
    end

    assert_match(/fallbacks cannot be combined with provider or model/, error.message)
  end

  def test_validate_rejects_empty_fallbacks
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
        root_recording: @root_recording,
        initiator: @initiator,
        prompt: "hello",
        fallbacks: []
      )
    end

    assert_match(/fallbacks must be a non-empty Array/, error.message)
  end
end

class GenerationParameterProfileFallbackTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class QueueProvider < RecordingStudioAI::Providers::Base
    attr_reader :calls

    def initialize(*results)
      @results = results
      @calls = []
    end

    def generate(request:, candidate:)
      calls << { request: request, candidate: candidate }
      @results.shift || raise("unexpected provider call")
    end
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
    isolate_allow_all_configuration!
    RecordingStudioAI.configuration.maximum_retries_per_candidate = 0
  end

  def test_profile_fallback_keeps_temperature_override_and_omits_unsupported_verbosity
    first = QueueProvider.new(failed_result)
    second = QueueProvider.new(success_result)
    configure_low_profile(first: first, second: second)

    response = RecordingStudioAI.generate(
      prompt: "hello",
      profile: :low,
      root_recording: @root_recording,
      initiator: @initiator,
      temperature: 1.0,
      verbosity: "high"
    )

    assert response.success?
    assert_equal 1, first.calls.length
    assert_equal 1, second.calls.length

    assert_in_delta 1.0, first.calls.first[:request][:temperature]
    assert_equal "high", first.calls.first[:request][:verbosity]
    assert_equal "gpt-5-mini", first.calls.first[:candidate].model

    assert_in_delta 1.0, second.calls.first[:request][:temperature]
    assert_nil second.calls.first[:request][:verbosity]
    assert_equal "gemini-2.5-flash", second.calls.first[:candidate].model
  end

  def test_profile_fallback_does_not_invent_temperature_when_caller_omitted_it
    first = QueueProvider.new(failed_result)
    second = QueueProvider.new(success_result)
    configure_low_profile(first: first, second: second)

    response = RecordingStudioAI.generate(
      prompt: "hello",
      profile: :low,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert response.success?
    assert_nil first.calls.first[:request][:temperature]
    assert_nil second.calls.first[:request][:temperature]
  end

  def test_profile_fallback_clamps_temperature_to_the_next_model_range
    first = QueueProvider.new(failed_result)
    second = QueueProvider.new(success_result)
    configure_low_profile(first: first, second: second)

    response = RecordingStudioAI.generate(
      prompt: "hello",
      profile: :low,
      root_recording: @root_recording,
      initiator: @initiator,
      temperature: 2.5
    )

    assert response.success?
    assert_in_delta 2.0, first.calls.first[:request][:temperature]
    assert_in_delta 2.0, second.calls.first[:request][:temperature]
  end

  def test_explicit_fallbacks_skip_profile_order_and_keep_temperature_override
    first = QueueProvider.new(failed_result)
    second = QueueProvider.new(success_result)
    configuration = RecordingStudioAI.configuration
    configuration.providers = { openai: first, gemini: second }
    configuration.profiles[:low] = [
      { provider: :gemini, model: "gemini-2.5-flash" },
      { provider: :openai, model: "gpt-5-mini" }
    ]

    response = RecordingStudioAI.generate(
      prompt: "hello",
      profile: :low,
      root_recording: @root_recording,
      initiator: @initiator,
      temperature: 1.0,
      verbosity: "high",
      fallbacks: [
        { provider: :openai, model: "gpt-5-mini" },
        { provider: :gemini, model: "gemini-2.5-flash" }
      ]
    )

    assert response.success?
    assert_equal "gpt-5-mini", first.calls.first[:candidate].model
    assert_equal "gemini-2.5-flash", second.calls.first[:candidate].model
    assert_in_delta 1.0, first.calls.first[:request][:temperature]
    assert_equal "high", first.calls.first[:request][:verbosity]
    assert_in_delta 1.0, second.calls.first[:request][:temperature]
    assert_nil second.calls.first[:request][:verbosity]
    assert_equal %w[primary fallback], response.attempts.map(&:kind)
  end

  private

  def configure_low_profile(first:, second:)
    configuration = RecordingStudioAI.configuration
    configuration.providers = { openai: first, gemini: second }
    configuration.profiles[:low] = [
      { provider: :openai, model: "gpt-5-mini" },
      { provider: :gemini, model: "gemini-2.5-flash" }
    ]
  end

  def success_result
    RecordingStudioAI::Providers::Result.new(text: "ok", finish_reason: "stop")
  end

  def failed_result
    RecordingStudioAI::Providers::Result.new(
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "timeout",
        code: "timeout",
        message: "Provider failed.",
        retryable: true,
        provider: "openai"
      )
    )
  end
end
