# frozen_string_literal: true

require "test_helper"

class GenerationParametersTest < Minitest::Test
  def setup
    @root_recording = Object.new
    @initiator = Object.new
    @original_authorization_handler = RecordingStudioAI.configuration.authorization_handler
    @original_attribution_validator = RecordingStudioAI.configuration.attribution_validator
    RecordingStudioAI.configuration.authorization_handler = ->(**) { true }
    RecordingStudioAI.configuration.attribution_validator = ->(**) {}
  end

  def teardown
    RecordingStudioAI.configuration.authorization_handler = @original_authorization_handler
    RecordingStudioAI.configuration.attribution_validator = @original_attribution_validator
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
      openai: Class.new(RecordingStudioAI::Providers::Base) {
        def configured? = true
      }.new,
      gemini: Class.new(RecordingStudioAI::Providers::Base) {
        def configured? = true
      }.new
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
end
