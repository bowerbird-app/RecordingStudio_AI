# frozen_string_literal: true

require "test_helper"
require "json"
require "stringio"

class ProviderCapabilityContractTest < Minitest::Test
  CONTRACT_CAPABILITIES = %i[
    generation streaming structured_output image_input file_input
    provider_native_web_search custom_tools provider_batch provider_batch_cancellation
  ].freeze

  ToolDefinition = Struct.new(:key, :provider_description, :json_schema)
  Batch = Struct.new(:provider_batch_id, :status)

  class OpenAIResponses
    attr_reader :requests, :stream_requests

    def initialize(responses:, stream_events:)
      @responses = responses
      @stream_events = stream_events
      @requests = []
      @stream_requests = []
    end

    def create(**request)
      requests << request
      @responses.shift || raise("unexpected OpenAI generation")
    end

    def stream(**request)
      stream_requests << request
      @stream_events.each
    end
  end

  class OpenAIFiles
    attr_reader :uploaded

    def create(file:, purpose:)
      @uploaded = file
      Struct.new(:id).new("file-1")
    end

    def content(_file_id)
      StringIO.new(JSON.generate(
        custom_id: "batch-item",
        response: {
          status_code: 200,
          request_id: "batch-request-1",
          body: { id: "batch-response-1", status: "completed", output_text: "batch answer" }
        }
      ) + "\n")
    end
  end

  class OpenAIBatches
    attr_reader :cancelled_id

    def create(**) = { id: "openai-batch-1", status: "validating" }
    def retrieve(*) = { id: "openai-batch-1", status: "completed", output_file_id: "output-1" }

    def cancel(batch_id)
      @cancelled_id = batch_id
      { id: batch_id, status: "cancelled" }
    end
  end

  OpenAIClient = Struct.new(:responses, :files, :batches)

  class GeminiModels
    attr_reader :requests, :stream_requests

    def initialize(responses:, stream_chunks:)
      @responses = responses
      @stream_chunks = stream_chunks
      @requests = []
      @stream_requests = []
    end

    def generate_content(**request)
      requests << request
      @responses.shift || raise("unexpected Gemini generation")
    end

    def stream_generate_content(**request)
      stream_requests << request
      @stream_chunks.each
    end
  end

  class GeminiClient
    attr_reader :models, :batch_requests, :cancelled_name

    def initialize(models)
      @models = models
    end

    def batch_generate_content(model:, requests:)
      @batch_requests = requests
      { "name" => "gemini-batch-1", "metadata" => { "state" => "JOB_STATE_PENDING" } }
    end

    def get_batch(name)
      return { "name" => name, "metadata" => { "state" => "JOB_STATE_CANCELLED" } } if cancelled_name

      {
        "name" => name,
        "metadata" => { "state" => "JOB_STATE_SUCCEEDED" },
        "response" => {
          "dest" => {
            "inlinedResponses" => [{
              "metadata" => { "key" => "batch-item" },
              "response" => {
                "responseId" => "batch-response-1",
                "candidates" => [{
                  "finishReason" => "STOP",
                  "content" => { "parts" => [{ "text" => "batch answer" }] }
                }]
              }
            }]
          }
        }
      }
    end

    def cancel_batch(name)
      @cancelled_name = name
      {}
    end
  end

  def test_openai_satisfies_shared_provider_capability_contract
    assert_provider_capability_contract(:openai)
  end

  def test_gemini_satisfies_shared_provider_capability_contract
    assert_provider_capability_contract(:gemini)
  end

  def test_default_profile_declarations_are_exactly_covered_by_contract
    declarations = RecordingStudioAI::Configuration.new.profiles.values.flatten

    assert_equal %i[gemini openai], declarations.map { |entry| entry.fetch(:provider) }.uniq.sort
    declarations.each do |entry|
      assert_equal CONTRACT_CAPABILITIES.sort, entry.fetch(:capabilities).sort,
                   "#{entry.fetch(:provider)} #{entry.fetch(:model)} changed the shared capability contract"
    end
  end

  private

  def assert_provider_capability_contract(provider)
    adapter, client = build_provider(provider)
    candidate = RecordingStudioAI::Candidate.new(
      provider: provider, model: "contract-model", capabilities: CONTRACT_CAPABILITIES
    )

    result = adapter.generate(request: advanced_request, candidate: candidate)
    assert result.success?
    assert_equal({ "summary" => "grounded" }, JSON.parse(result.text))
    assert_equal ["web_search"], result.provider_native_tools
    assert_equal "lookup_topic", result.tool_calls.first.key
    assert_advanced_translation(provider, client)

    continuation = adapter.generate(request: continuation_request, candidate: candidate)
    assert continuation.success?
    assert_equal "continued", continuation.text
    assert_continuation_translation(provider, client)

    events = []
    streamed = adapter.stream(request: base_request, candidate: candidate) { |event| events << event }
    assert streamed.success?
    assert_equal "streamed", streamed.text
    assert_equal ["streamed"], events.filter_map(&:text_delta)

    submitted = adapter.submit_batch(request: batch_request, candidate: candidate)
    assert_equal "submitted", submitted.status
    refreshed = adapter.refresh_batch(
      batch: Batch.new(submitted.provider_batch_id, submitted.status), candidate: candidate
    )
    assert_equal "batch answer", refreshed.items.first.text
    cancelled = adapter.cancel_batch(
      batch: Batch.new(submitted.provider_batch_id, "processing"), candidate: candidate
    )
    assert_equal "cancelled", cancelled.status
    assert_batch_translation(provider, client)
  end

  def build_provider(provider)
    configuration = RecordingStudioAI::Configuration.new
    if provider == :openai
      responses = OpenAIResponses.new(
        responses: [openai_advanced_response, openai_continuation_response],
        stream_events: openai_stream_events
      )
      client = OpenAIClient.new(responses, OpenAIFiles.new, OpenAIBatches.new)
      configuration.openai_client = client
      [RecordingStudioAI::Adapters::OpenAI.new(configuration: configuration), client]
    else
      models = GeminiModels.new(
        responses: [gemini_advanced_response, gemini_continuation_response],
        stream_chunks: gemini_stream_chunks
      )
      client = GeminiClient.new(models)
      configuration.gemini_client = client
      [RecordingStudioAI::Adapters::Gemini.new(configuration: configuration), client]
    end
  end

  def base_request
    {
      prompt: "Summarize", messages: [], system_instruction: nil, attachments: [],
      provider_native_tools: [], schema: nil, custom_tool_definitions: [], custom_tool_history: []
    }
  end

  def advanced_request
    base_request.merge(
      schema: schema,
      attachments: [
        { type: :image, content_type: "image/png", data: "image-bytes", filename: "image.png" },
        { type: :file, content_type: "text/plain", data: "file-bytes", filename: "notes.txt" }
      ],
      provider_native_tools: [:web_search],
      custom_tool_definitions: [ToolDefinition.new("lookup_topic", "Looks up a topic.", tool_schema)]
    )
  end

  def continuation_request
    base_request.merge(custom_tool_history: [{
      calls: [{ provider_tool_call_id: "call-1", key: "lookup_topic", arguments: { "topic" => "Rails" } }],
      results: [{ provider_tool_call_id: "call-1", tool_key: "lookup_topic", result: { "found" => true } }]
    }])
  end

  def batch_request
    { items: [base_request.merge(reference: "batch-item", prompt: "Batch prompt")] }
  end

  def schema
    {
      "type" => "object",
      "properties" => { "summary" => { "type" => "string" } },
      "required" => ["summary"],
      "additionalProperties" => false
    }
  end

  def tool_schema
    {
      "type" => "object",
      "properties" => { "topic" => { "type" => "string" } },
      "required" => ["topic"],
      "additionalProperties" => false
    }
  end

  def assert_advanced_translation(provider, client)
    request = provider == :openai ? client.responses.requests.first : client.models.requests.first
    if provider == :openai
      assert_equal "json_schema", request.dig(:text, :format, :type)
      assert_equal %w[input_text input_image input_file], request.dig(:input, 0, :content).map { |part| part[:type] }
      assert_equal %w[web_search function], request.fetch(:tools).map { |tool| tool[:type] }
    else
      assert_equal schema, request.dig(:config, :response_json_schema)
      assert_equal %i[text inline_data inline_data], request.dig(:contents, 0, :parts).flat_map(&:keys)
      assert_equal({ google_search: {} }, request.dig(:config, :tools, 0))
      assert_equal "lookup_topic", request.dig(:config, :tools, 1, :function_declarations, 0, :name)
    end
  end

  def assert_continuation_translation(provider, client)
    request = provider == :openai ? client.responses.requests.last : client.models.requests.last
    if provider == :openai
      assert_equal %w[function_call function_call_output], request.fetch(:input).last(2).map { |item| item[:type] }
      assert_equal "call-1", request.fetch(:input).last.fetch(:call_id)
    else
      assert_equal %w[model user], request.fetch(:contents).last(2).map { |content| content[:role] }
      assert_equal true, request.dig(:contents, -1, :parts, 0, :function_response, :response, :result, "found")
    end
  end

  def assert_batch_translation(provider, client)
    if provider == :openai
      line = JSON.parse(client.files.uploaded.string.lines.first)
      assert_equal "batch-item", line.fetch("custom_id")
      assert_equal "/v1/responses", line.fetch("url")
      assert_equal "openai-batch-1", client.batches.cancelled_id
    else
      assert_equal "batch-item", client.batch_requests.first.fetch(:key)
      assert_equal "Batch prompt", client.batch_requests.first.dig(:contents, 0, :parts, 0, :text)
      assert_equal "gemini-batch-1", client.cancelled_name
    end
  end

  def openai_advanced_response
    {
      id: "openai-advanced", output_text: '{"summary":"grounded"}', status: "completed",
      output: [
        { type: "function_call", call_id: "call-1", name: "lookup_topic", arguments: '{"topic":"Rails"}' },
        { type: "web_search_call", status: "completed" }
      ]
    }
  end

  def openai_continuation_response
    { id: "openai-continuation", output_text: "continued", status: "completed", output: [] }
  end

  def openai_stream_events
    [
      { type: "response.output_text.delta", delta: "streamed" },
      { type: "response.completed", response: {
        id: "openai-stream", output_text: "streamed", status: "completed", output: []
      } }
    ]
  end

  def gemini_advanced_response
    {
      "responseId" => "gemini-advanced",
      "candidates" => [{
        "finishReason" => "STOP",
        "content" => { "parts" => [
          { "text" => '{"summary":"grounded"}' },
          { "functionCall" => { "name" => "lookup_topic", "args" => { "topic" => "Rails" } } }
        ] },
        "groundingMetadata" => {
          "groundingChunks" => [{ "web" => { "title" => "Source", "uri" => "https://example.test" } }]
        }
      }]
    }
  end

  def gemini_continuation_response
    {
      "responseId" => "gemini-continuation",
      "candidates" => [{ "finishReason" => "STOP", "content" => { "parts" => [{ "text" => "continued" }] } }]
    }
  end

  def gemini_stream_chunks
    [{
      "responseId" => "gemini-stream",
      "candidates" => [{ "finishReason" => "STOP", "content" => { "parts" => [{ "text" => "streamed" }] } }]
    }]
  end
end