# frozen_string_literal: true

require "test_helper"

class PhaseSevenAdvancedCapabilitiesTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)
  OpenAIClient = Struct.new(:responses)
  GeminiClient = Struct.new(:models)

  class Requests
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def create(**request)
      requests << request
      @response
    end
  end

  class Models
    attr_reader :requests

    def initialize(response)
      @response = response
      @requests = []
    end

    def generate_content(**request)
      requests << request
      @response
    end
  end

  def setup
    super
    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(41)
    isolate_allow_all_configuration!
  end

  def test_openai_translates_schema_image_and_web_search_and_persists_only_safe_metadata
    provider_response = {
      id: "resp_advanced",
      output_text: '{"summary":"done"}',
      status: "completed",
      output: [
        {
          type: "message",
          content: [{
            type: "output_text",
            text: '{"summary":"done"}',
            annotations: [{
              type: "url_citation",
              title: "Source",
              url: "https://example.test/source",
              start_index: 0,
              end_index: 4
            }]
          }]
        },
        { type: "web_search_call", status: "completed" }
      ]
    }
    responses = Requests.new(provider_response)
    configure_provider(:openai, OpenAIClient.new(responses))
    image_bytes = "\x89PNG\r\n\x1A\nimage-data".b

    response = RecordingStudioAI.generate!(
      prompt: "Describe this image",
      schema: object_schema,
      attachments: [{
        type: :image,
        content_type: "image/png",
        data: image_bytes,
        filename: "private-name.png"
      }],
      provider_native_tools: [:web_search],
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal({ "summary" => "done" }, response.structured_data)
    assert_equal 1, response.citations.length
    assert_equal "https://example.test/source", response.citations.first.url
    assert_equal ["web_search"], response.provider_native_tools

    request = responses.requests.first
    assert_equal "json_schema", request.dig(:text, :format, :type)
    assert_equal object_schema, request.dig(:text, :format, :schema)
    assert_equal [{ type: "web_search" }], request[:tools]
    assert(request[:input].first[:content].any? { |part| part[:type] == "input_image" })

    run = RecordingStudioAI::Run.first
    attempt = RecordingStudioAI::Attempt.first
    assert_equal 1, run.attachment_count
    assert_equal image_bytes.bytesize, run.attachment_total_bytes
    assert_equal ["image/png"], run.attachment_content_types
    assert_equal 1, run.citation_count
    assert run.web_search_requested
    assert run.web_search_used
    assert_equal 1, attempt.attachment_count
    assert_equal 0, attempt.provider_file_count
    assert_equal 1, attempt.citation_count
    refute_includes run.attributes.values, image_bytes
    refute_includes run.attributes.values, "private-name.png"
    refute_includes attempt.attributes.values, image_bytes
  end

  def test_gemini_translates_schema_file_and_grounding_citations
    provider_response = {
      "responseId" => "gem_advanced",
      "candidates" => [{
        "content" => { "parts" => [{ "text" => '{"summary":"grounded"}' }] },
        "finishReason" => "STOP",
        "groundingMetadata" => {
          "groundingChunks" => [{
            "web" => { "title" => "Gemini source", "uri" => "https://example.test/gemini" }
          }],
          "groundingSupports" => [{
            "groundingChunkIndices" => [0],
            "segment" => { "startIndex" => 1, "endIndex" => 5 }
          }]
        }
      }]
    }
    models = Models.new(provider_response)
    configure_provider(:gemini, GeminiClient.new(models))

    response = RecordingStudioAI.generate!(
      prompt: "Read this file",
      schema: object_schema,
      attachments: [{ type: :file, content_type: "text/plain", data: "private file" }],
      provider_native_tools: [:web_search],
      provider: :gemini,
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_equal({ "summary" => "grounded" }, response.structured_data)
    assert_equal "https://example.test/gemini", response.citations.first.url
    request = models.requests.first
    assert_equal "application/json", request.dig(:config, :response_mime_type)
    assert_equal object_schema, request.dig(:config, :response_json_schema)
    assert_equal [{ google_search: {} }], request.dig(:config, :tools)
    inline_data = request[:contents].first[:parts].find { |part| part[:inline_data] }
    assert_equal "text/plain", inline_data.dig(:inline_data, :mime_type)
    refute_equal "private file", inline_data.dig(:inline_data, :data)
    assert_equal 0, RecordingStudioAI::Attempt.first.provider_file_count
  end

  def test_schema_validation_failure_returns_failed_response_and_attempt
    responses = Requests.new(
      id: "resp_invalid_schema",
      output_text: '{"wrong":"value"}',
      status: "completed",
      output: []
    )
    configure_provider(:openai, OpenAIClient.new(responses))

    response = RecordingStudioAI.generate(
      prompt: "Return structured data",
      schema: object_schema,
      provider: :openai,
      root_recording: @root_recording,
      initiator: @initiator
    )

    refute response.success?
    assert_equal "schema_validation", response.error.category
    assert_nil response.structured_data
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
    refute_includes RecordingStudioAI::Attempt.first.attributes.values, '{"wrong":"value"}'
  end

  def test_invalid_attachment_is_rejected_before_run_or_provider_contact
    responses = Requests.new({})
    configure_provider(:openai, OpenAIClient.new(responses))

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Inspect",
        attachments: [{ type: :image, content_type: "image/png", data: "not-a-png" }],
        provider: :openai,
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "attachment_validation", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty responses.requests
  end

  def test_attachments_require_a_user_message_target
    responses = Requests.new({})
    configure_provider(:openai, OpenAIClient.new(responses))

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        messages: [{ role: "assistant", content: "Earlier response" }],
        attachments: [{ type: :file, content_type: "text/plain", data: "private file" }],
        provider: :openai,
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "attachment_validation", error.code
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty responses.requests
  end

  def test_web_search_requires_tool_authorization_before_provider_contact
    responses = Requests.new({})
    configure_provider(:openai, OpenAIClient.new(responses))
    actions = []
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, **|
      actions << action
      action != "recording_studio_ai.use_provider_native_tool"
    end

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Search",
        provider_native_tools: [:web_search],
        provider: :openai,
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal ["recording_studio_ai.execute", "recording_studio_ai.use_provider_native_tool"], actions
    assert_equal 0, RecordingStudioAI::Run.count
    assert_empty responses.requests
  end

  def test_internal_gemini_client_translates_advanced_configuration
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, '{"responseId":"gem-advanced-rest"}')
      response
    end

    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      client.generate_content(
        model: "gemini-test",
        contents: [{ role: "user", parts: [{ text: "Prompt" }] }],
        config: {
          response_mime_type: "application/json",
          response_json_schema: object_schema,
          tools: [{ google_search: {} }]
        }
      )
    end

    body = JSON.parse(captured_request.body)
    assert_equal "application/json", body.dig("generationConfig", "responseMimeType")
    assert_equal object_schema, body.dig("generationConfig", "responseJsonSchema")
    assert_equal [{ "googleSearch" => {} }], body.fetch("tools")
    refute_includes captured_request.path, "Prompt"
  end

  def test_attachment_filename_extension_must_match_content_type
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Inspect",
        attachments: [{ type: :file, content_type: "text/plain", data: "text", filename: "private.pdf" }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "attachment_validation", error.code
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_non_image_attachment_data_must_match_declared_content_type
    {
      "application/pdf" => "not a PDF",
      "application/json" => "not JSON",
      "text/plain" => "binary\0text"
    }.each do |content_type, data|
      error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI.generate(
          prompt: "Inspect",
          attachments: [{ type: :file, content_type: content_type, data: data }],
          root_recording: @root_recording,
          initiator: @initiator
        )
      end

      assert_equal "attachment_validation", error.code
    end
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_attachment_kind_must_match_declared_content_type
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Inspect",
        attachments: [{ type: :file, content_type: "image/png", data: "not an image" }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "attachment_validation", error.code
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_schema_must_be_a_valid_json_schema_hash
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Structure this",
        schema: { "type" => "not-a-json-schema-type" },
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "invalid_request", error.code
    assert_equal 0, RecordingStudioAI::Run.count
  end

  private

  def object_schema
    {
      "type" => "object",
      "properties" => { "summary" => { "type" => "string" } },
      "required" => ["summary"],
      "additionalProperties" => false
    }
  end

  def configure_provider(provider, client)
    configuration = RecordingStudioAI.configuration
    configuration.public_send("#{provider}_client=", client)
    configuration.allowed_provider_overrides = [provider]
  end
end
