# frozen_string_literal: true

require "test_helper"

class PhaseSixSynchronousProvidersTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)
  Value = Struct.new(:attributes) do
    def method_missing(name, *)
      return attributes[name] if attributes.key?(name)

      super
    end

    def respond_to_missing?(name, include_private = false)
      attributes.key?(name) || super
    end
  end

  class OpenAIResponses
    attr_reader :requests

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
      @requests = []
    end

    def create(**request)
      requests << request
      raise @error if @error

      @response
    end
  end

  OpenAIClient = Struct.new(:responses)
  GeminiModels = Struct.new(:response, :requests) do
    def generate_content(**request)
      requests << request
      response
    end
  end
  GeminiClient = Struct.new(:models)
  ProviderFailure = Class.new(StandardError) do
    attr_reader :status, :code

    def initialize(status:, code:)
      @status = status
      @code = code
      super("sensitive provider payload")
    end
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(29)
    isolate_allow_all_configuration!
  end

  def test_openai_generate_translates_and_normalizes_responses_api
    usage = Value.new({
                        input_tokens: 12,
                        output_tokens: 8,
                        total_tokens: 20,
                        input_tokens_details: Value.new({ cached_tokens: 3 }),
                        output_tokens_details: Value.new({ reasoning_tokens: 2 })
                      })
    provider_response = Value.new({
                                    id: "resp_123",
                                    output_text: "OpenAI answer",
                                    status: :completed,
                                    usage: usage
                                  })
    responses = OpenAIResponses.new(response: provider_response)
    configure_provider(:openai, OpenAIClient.new(responses), "gpt-test")

    response = RecordingStudioAI.generate!(
      prompt: "Summarize",
      system_instruction: "Be concise",
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal "OpenAI answer", response.text
    assert_equal "resp_123", RecordingStudioAI::Attempt.first.provider_request_id
    assert_equal "completed", response.finish_reason
    assert_equal 12, response.usage.input_tokens
    assert_equal 8, response.usage.output_tokens
    assert_equal 20, response.usage.total_tokens
    assert_equal 3, response.usage.cached_input_tokens
    assert_equal 2, response.usage.reasoning_tokens
    assert_nil response.cost
    assert_equal(
      { model: "gpt-test", input: "Summarize", instructions: "Be concise", store: false },
      responses.requests.first
    )
    refute_same provider_response, response
    refute_includes response.to_h.values, provider_response
  end

  def test_openai_messages_preserve_normalized_roles
    responses = OpenAIResponses.new(response: Value.new({
                                                          id: "resp_messages",
                                                          output_text: "Reply",
                                                          status: :completed,
                                                          usage: nil
                                                        }))
    configure_provider(:openai, OpenAIClient.new(responses), "gpt-test")

    RecordingStudioAI.generate!(
      messages: [
        { role: "user", content: "Question" },
        { role: "assistant", content: "Earlier answer" }
      ],
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal(
      [
        { role: "user", content: "Question" },
        { role: "assistant", content: "Earlier answer" }
      ],
      responses.requests.first[:input]
    )
  end

  def test_gemini_generate_translates_roles_and_normalizes_response
    provider_response = {
      "responseId" => "gem_123",
      "candidates" => [{
        "content" => { "parts" => [{ "text" => "Gemini answer" }] },
        "finishReason" => "STOP"
      }],
      "usageMetadata" => {
        "promptTokenCount" => 9,
        "candidatesTokenCount" => 6,
        "totalTokenCount" => 15,
        "cachedContentTokenCount" => 1,
        "thoughtsTokenCount" => 2
      }
    }
    models = GeminiModels.new(provider_response, [])
    configure_provider(:gemini, GeminiClient.new(models), "gemini-test")

    response = RecordingStudioAI.generate!(
      messages: [
        { role: "system", content: "Be concise" },
        { role: "user", content: "Question" },
        { role: "assistant", content: "Earlier answer" }
      ],
      provider: :gemini,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal "Gemini answer", response.text
    assert_equal "gem_123", RecordingStudioAI::Attempt.first.provider_request_id
    assert_equal "stop", response.finish_reason
    assert_equal 9, response.usage.input_tokens
    assert_equal 6, response.usage.output_tokens
    assert_equal 15, response.usage.total_tokens
    assert_equal 1, response.usage.cached_input_tokens
    assert_equal 2, response.usage.reasoning_tokens
    assert_equal "gemini-test", models.requests.first[:model]
    assert_equal(
      [
        { role: "user", parts: [{ text: "Question" }] },
        { role: "model", parts: [{ text: "Earlier answer" }] }
      ],
      models.requests.first[:contents]
    )
    assert_equal({ system_instruction: "Be concise" }, models.requests.first[:config])
    refute_includes response.to_h.values, provider_response
  end

  def test_provider_failure_is_normalized_and_generate_bang_raises
    failure = ProviderFailure.new(status: 429, code: "rate_limit_exceeded")
    responses = OpenAIResponses.new(error: failure)
    configure_provider(:openai, OpenAIClient.new(responses), "gpt-test")

    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "rate_limit", response.error.category
    assert_equal "rate_limit_exceeded", response.error.provider_code
    assert response.error.retryable?
    refute_includes response.error.message, "sensitive"
    assert_equal "failed", RecordingStudioAI::Attempt.first.status

    assert_raises(RecordingStudioAI::Errors::ExecutionError) do
      RecordingStudioAI.generate!(
        prompt: "Summarize again",
        provider: :openai,
        root_recording: @root_recording,
        initiator: @initiator
      )
    end
  end

  def test_openai_failed_response_is_normalized_without_exposing_provider_payload
    provider_response = Value.new({
                                    id: "resp_failed",
                                    output_text: "",
                                    status: :failed,
                                    usage: nil,
                                    error: Value.new({ code: "model_error", message: "sensitive provider payload" })
                                  })
    configure_provider(:openai, OpenAIClient.new(OpenAIResponses.new(response: provider_response)), "gpt-test")

    response = RecordingStudioAI.generate(
      prompt: "Summarize",
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "provider_error", response.error.category
    assert_equal "model_error", response.error.provider_code
    refute_includes response.error.message, "sensitive"
  end

  def test_system_instruction_is_rejected_with_messages
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        messages: [{ role: "user", content: "Question" }],
        system_instruction: "Duplicate system channel",
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "invalid_request", error.code
  end

  def test_internal_gemini_client_sends_content_and_system_instruction_without_retaining_them
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, '{"responseId":"gem-rest"}')
      response
    end

    result = Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      client.generate_content(
        model: "gemini-test",
        contents: [{ role: "user", parts: [{ text: "Sensitive prompt" }] }],
        config: { system_instruction: "Sensitive instruction" }
      )
    end

    assert_equal "gem-rest", result.fetch("responseId")
    body = JSON.parse(captured_request.body)
    assert_equal "Sensitive prompt", body.dig("contents", 0, "parts", 0, "text")
    assert_equal "Sensitive instruction", body.dig("systemInstruction", "parts", 0, "text")
    refute_includes captured_request.path, "Sensitive"
  end

  def test_official_openai_transport_errors_are_retryable_and_normalized
    require "openai"
    url = URI("https://api.openai.com/v1/responses")

    timeout = OpenAI::Errors::APITimeoutError.new(url: url)
    timeout_error = RecordingStudioAI::Providers::ProviderError.normalize(timeout, provider: :openai)
    assert_equal "timeout", timeout_error.category
    assert timeout_error.retryable?

    connection = OpenAI::Errors::APIConnectionError.new(url: url)
    connection_error = RecordingStudioAI::Providers::ProviderError.normalize(connection, provider: :openai)
    assert_equal "connection", connection_error.category
    assert connection_error.retryable?
  end

  private

  def configure_provider(provider, client, model)
    configuration = RecordingStudioAI.configuration
    configuration.public_send("#{provider}_client=", client)
    configuration.allowed_provider_overrides = [provider]
    configuration.profiles[:medium] = [
      { provider: provider, model: model, capabilities: %i[generation] }
    ]
  end
end
