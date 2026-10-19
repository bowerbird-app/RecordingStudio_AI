# frozen_string_literal: true

require "test_helper"

class OpenAIModelWireTest < Minitest::Test
  ResponseClient = Struct.new(:params) do
    def responses
      self
    end

    def create(**params)
      self.params = params
      {
        id: "resp_1", status: "completed", output_text: "ok", output: [],
        usage: { input_tokens: 1, output_tokens: 1, total_tokens: 2 }
      }
    end
  end

  def setup
    @client = ResponseClient.new
    configuration = RecordingStudioAI::Configuration.new
    configuration.openai_client = @client
    @adapter = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
  end

  def test_generation_sends_the_replacement_and_maps_minimal_effort
    @adapter.generate(request: request(reasoning_effort: "minimal"), candidate: candidate("gpt-5-mini"))

    assert_equal "gpt-5.6-terra", @client.params[:model]
    assert_equal({ effort: "none" }, @client.params[:reasoning])
    assert_equal false, @client.params[:store]
  end

  def test_dated_snapshot_alias_uses_the_same_replacement
    @adapter.generate(request: request, candidate: candidate("gpt-5-2025-08-07"))

    assert_equal "gpt-5.6-sol", @client.params[:model]
    refute @client.params.key?(:reasoning)
  end

  def test_pro_sends_reasoning_mode_and_rejects_low_effort
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      @adapter.generate(request: request(reasoning_effort: "low"), candidate: candidate("gpt-5-pro"))
    end

    assert_equal "invalid_request", error.code
    assert_match(/reasoning_effort/, error.message)
    assert_nil @client.params
  end

  def test_pro_sends_an_allowed_effort
    @adapter.generate(request: request(reasoning_effort: "xhigh"), candidate: candidate("gpt-5-pro"))

    assert_equal "gpt-5.6-sol", @client.params[:model]
    assert_equal({ mode: "pro", effort: "xhigh" }, @client.params[:reasoning])
  end

  def test_pro_keeps_an_explicit_high_effort_when_none_is_given
    @adapter.generate(request: request, candidate: candidate("gpt-5-pro-2025-10-06"))

    assert_equal({ mode: "pro", effort: "high" }, @client.params[:reasoning])
  end

  private

  def candidate(model)
    RecordingStudioAI::Candidate.new(provider: :openai, model: model, capabilities: [:generation])
  end

  def request(reasoning_effort: nil)
    {
      prompt: "hello", messages: nil, system_instruction: nil, attachments: [],
      provider_native_tools: [], custom_tools: [], schema: nil, temperature: nil,
      max_output_tokens: nil, verbosity: nil, reasoning_effort: reasoning_effort
    }
  end
end
