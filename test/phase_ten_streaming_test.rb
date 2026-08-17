# frozen_string_literal: true

require "test_helper"
require "active_record"

migration_file = Dir[File.expand_path("../db/migrate/*_create_recording_studio_ai_persistence_tables.rb", __dir__)].first
require migration_file
require_relative "../db/migrate/20260814120000_add_prompt_attribution_to_recording_studio_ai_runs"
require_relative "../db/migrate/20260812150000_remove_correlation_ids_from_recording_studio_ai"

require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"
require_relative "../app/models/recording_studio_ai/custom_tool_invocation"

class PhaseTenStreamingTest < Minitest::Test
  Actor = Struct.new(:id)
  OpenAIClient = Struct.new(:responses)
  GeminiClient = Struct.new(:models)

  class StreamProvider < RecordingStudioAI::Providers::Base
    attr_reader :requests

    def initialize(*streams)
      @streams = streams
      @requests = []
    end

    def stream(request:, candidate:)
      requests << { request: request, candidate: candidate }
      events, result = @streams.shift || raise("unexpected stream")
      events.each { |event| yield event }
      result
    end
  end

  class StalledStreamProvider < RecordingStudioAI::Providers::Base
    attr_reader :worker

    def stream(request:, candidate:)
      @worker = Thread.current
      Queue.new.pop
    end
  end

  class OpenAIStreams
    attr_reader :requests

    def initialize(events)
      @events = events
      @requests = []
    end

    def stream(**request)
      requests << request
      @events.each
    end
  end

  class GeminiStreams
    attr_reader :requests

    def initialize(chunks)
      @chunks = chunks
      @requests = []
    end

    def stream_generate_content(**request)
      requests << request
      @chunks.each
    end
  end

  class FragmentedResponse
    def initialize(*chunks)
      @chunks = chunks
    end

    def read_body
      @chunks.each { |chunk| yield chunk }
    end
  end

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    bootstrap_external_recording_studio_table
    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
      AddPromptAttributionToRecordingStudioAIRuns.migrate(:up)
      RemoveCorrelationIdsFromRecordingStudioAI.migrate(:up)
    end

    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(91)
    @original_configuration = RecordingStudioAI.instance_variable_get(:@configuration)
    @original_tools = RecordingStudioAI.instance_variable_get(:@tools)
    RecordingStudioAI.instance_variable_set(:@configuration, RecordingStudioAI::Configuration.new)
    RecordingStudioAI.configuration.attribution_validator = ->(**) {}
    RecordingStudioAI.configuration.authorization_handler = ->(**) { true }
    RecordingStudioAI.instance_variable_set(:@tools, RecordingStudioAI::Tools::Registry.new)
  end

  def teardown
    RecordingStudioAI.instance_variable_set(:@configuration, @original_configuration)
    RecordingStudioAI.instance_variable_set(:@tools, @original_tools)
    ActiveRecord::Base.connection_pool.disconnect! if ActiveRecord::Base.connected?
  end

  def test_stream_emits_normalized_events_and_persists_assembled_execution_only
    usage = RecordingStudioAI::Contracts::Usage.new(input_tokens: 4, output_tokens: 2, total_tokens: 6)
    provider = StreamProvider.new([
      [
        stream_event(:text_delta, text_delta: "Hello "),
        stream_event(:text_delta, text_delta: "world")
      ],
      RecordingStudioAI::Providers::Result.new(
        text: "Hello world",
        usage: usage,
        provider_request_id: "stream-1",
        finish_reason: "stop"
      )
    ])
    configure_provider(provider)
    events = []

    response = stream { |event| events << event }

    assert response.success?
    assert_equal "stream", response.operation
    assert_equal "Hello world", response.text
    assert_equal %w[text_delta text_delta usage completed], events.map(&:type)
    assert_equal "Hello world", events.filter_map(&:text_delta).join
    assert_equal 6, events.find { |event| event.type == "usage" }.usage.total_tokens
    assert events.all? { |event| event.is_a?(RecordingStudioAI::Contracts::StreamingEvent) }

    run = RecordingStudioAI::Run.first
    attempt = RecordingStudioAI::Attempt.first
    assert_equal "stream", run.operation
    assert_equal "completed", run.status
    assert_equal "completed", attempt.status
    assert attempt.streaming
    assert_equal "stream-1", attempt.provider_request_id
    refute_includes run.attributes.values, "Hello world"
    refute_includes attempt.attributes.values, "Hello "
  end

  def test_stream_failure_emits_error_without_completed
    error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "provider_unavailable",
      code: "http_503",
      message: "Provider is unavailable.",
      retryable: false,
      provider: "test"
    )
    provider = StreamProvider.new([[], RecordingStudioAI::Providers::Result.new(error: error)])
    configure_provider(provider)
    events = []

    response = stream { |event| events << event }

    refute response.success?
    assert_equal ["error"], events.map(&:type)
    assert_equal "http_503", events.first.error.code
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
  end

  def test_stream_idle_timeout_terminalizes_execution
    provider = StalledStreamProvider.new
    configure_provider(provider)
    RecordingStudioAI.configuration.stream_idle_timeout = 0.01
    events = []

    response = stream { |event| events << event }

    refute response.success?
    assert_equal "stream_idle_timeout", response.error.code
    assert_equal ["error"], events.map(&:type)
    assert_equal "failed", RecordingStudioAI::Run.first.status
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
    refute provider.worker.alive?
  end

  def test_retryable_failure_retries_before_visible_output
    failure = RecordingStudioAI::Providers::Result.new(
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "provider_unavailable",
        code: "http_503",
        message: "Provider is unavailable.",
        retryable: true,
        provider: "test"
      )
    )
    provider = StreamProvider.new(
      [[], failure],
      [[stream_event(:text_delta, text_delta: "Recovered")], RecordingStudioAI::Providers::Result.new(text: "Recovered")]
    )
    configure_provider(provider)
    events = []

    response = stream { |event| events << event }

    assert response.success?
    assert_equal %w[primary retry], response.attempts.map(&:kind)
    assert_equal %w[text_delta completed], events.map(&:type)
  end

  def test_retryable_failure_does_not_retry_after_visible_output
    failure = RecordingStudioAI::Providers::Result.new(
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "connection",
        code: "connection",
        message: "Connection failed.",
        retryable: true,
        provider: "test"
      )
    )
    provider = StreamProvider.new(
      [[stream_event(:text_delta, text_delta: "Partial")], failure],
      [[stream_event(:text_delta, text_delta: "must not run")], RecordingStudioAI::Providers::Result.new(text: "no")]
    )
    configure_provider(provider)
    events = []

    response = stream { |event| events << event }

    refute response.success?
    assert_equal %w[text_delta error], events.map(&:type)
    assert_equal 1, provider.requests.length
  end

  def test_consumer_exception_cancels_records_and_propagates
    provider = StreamProvider.new(
      [[stream_event(:text_delta, text_delta: "Hi")], RecordingStudioAI::Providers::Result.new(text: "Hi")]
    )
    configure_provider(provider)

    error = assert_raises(RuntimeError) do
      stream { |_event| raise "consumer disconnected" }
    end

    assert_equal "consumer disconnected", error.message
    assert_equal "cancelled", RecordingStudioAI::Run.first.status
    assert_equal "cancelled", RecordingStudioAI::Attempt.first.status
    assert_equal "stream_cancelled", RecordingStudioAI::Attempt.first.error_code
  end

  def test_stream_without_block_returns_enumerator
    provider = StreamProvider.new(
      [[stream_event(:text_delta, text_delta: "Hi")], RecordingStudioAI::Providers::Result.new(text: "Hi")]
    )
    configure_provider(provider)

    events = RecordingStudioAI.stream(**stream_arguments).to_a

    assert_equal %w[text_delta completed], events.map(&:type)
  end

  def test_stopping_enumerator_early_cancels_active_records
    provider = StreamProvider.new(
      [[stream_event(:text_delta, text_delta: "Hi"), stream_event(:text_delta, text_delta: " later")],
       RecordingStudioAI::Providers::Result.new(text: "Hi later")]
    )
    configure_provider(provider)

    RecordingStudioAI.stream(**stream_arguments).each { |_event| break }

    assert_equal "cancelled", RecordingStudioAI::Run.first.status
    assert_equal "cancelled", RecordingStudioAI::Attempt.first.status
    assert_equal "stream_cancelled", RecordingStudioAI::Attempt.first.error_code
  end

  def test_openai_stream_normalizes_deltas_citations_and_final_usage
    response = {
      id: "resp-stream",
      status: "completed",
      usage: { input_tokens: 3, output_tokens: 2, total_tokens: 5 },
      output: [{
        type: "message",
        content: [{
          type: "output_text",
          text: "Hello",
          annotations: [{ type: "url_citation", title: "Source", url: "https://example.test", start_index: 0, end_index: 5 }]
        }]
      }]
    }
    streams = OpenAIStreams.new([
      { type: "response.output_text.delta", delta: "Hel" },
      { type: "response.output_text.delta", delta: "lo" },
      { type: "response.completed", response: response }
    ])
    configure_external_provider(:openai, OpenAIClient.new(streams))
    events = []

    result = stream(provider: :openai) { |event| events << event }

    assert result.success?
    assert_equal "Hello", result.text
    assert_equal %w[text_delta text_delta citation usage completed], events.map(&:type)
    assert_equal "https://example.test", events.find { |event| event.type == "citation" }.citation.url
    assert_equal false, streams.requests.first[:store]
  end

  def test_openai_transient_terminal_error_retries_before_output
    streams = OpenAIStreams.new([
      { type: "error", error: { code: "rate_limit_exceeded" } }
    ])
    configure_external_provider(:openai, OpenAIClient.new(streams))
    events = []

    result = stream(provider: :openai) { |event| events << event }

    refute result.success?
    assert result.error.retryable?
    assert_equal "rate_limit", result.error.category
    assert_equal 2, streams.requests.length
    assert_equal %w[primary retry], result.attempts.map(&:kind)
    assert_equal ["error"], events.map(&:type)
  end

  def test_openai_failed_response_preserves_transient_retry_classification
    failed_response = {
      id: "resp-failed",
      status: "failed",
      error: { code: "server_error" }
    }
    streams = OpenAIStreams.new([
      { type: "response.failed", response: failed_response }
    ])
    configure_external_provider(:openai, OpenAIClient.new(streams))

    result = stream(provider: :openai) { |_event| }

    refute result.success?
    assert result.error.retryable?
    assert_equal "provider_unavailable", result.error.category
    assert_equal 2, streams.requests.length
  end

  def test_gemini_stream_normalizes_chunks_citations_and_usage
    streams = GeminiStreams.new([
      {
        "responseId" => "gem-stream",
        "candidates" => [{ "content" => { "parts" => [{ "text" => "Gem" }] }, "finishReason" => "STOP" }]
      },
      {
        "responseId" => "gem-stream",
        "candidates" => [{
          "content" => { "parts" => [{ "text" => "ini" }] },
          "finishReason" => "STOP",
          "groundingMetadata" => {
            "groundingChunks" => [{ "web" => { "title" => "Source", "uri" => "https://example.test/gem" } }]
          }
        }],
        "usageMetadata" => { "promptTokenCount" => 2, "candidatesTokenCount" => 2, "totalTokenCount" => 4 }
      }
    ])
    configure_external_provider(:gemini, GeminiClient.new(streams))
    events = []

    result = stream(provider: :gemini) { |event| events << event }

    assert result.success?
    assert_equal "Gemini", result.text
    assert_equal %w[text_delta text_delta citation usage completed], events.map(&:type)
    assert_equal "https://example.test/gem", result.citations.first.url
  end

  def test_gemini_stream_normalizes_cumulative_text_snapshots
    stream_chunk = RecordingStudioAI::ProviderClients::Gemini::StreamChunk
    streams = GeminiStreams.new([
      stream_chunk.new(payload: {
        "responseId" => "gem-stream",
        "candidates" => [{ "content" => { "parts" => [{ "text" => "Gem" }] } }]
      }, text_mode: :cumulative),
      stream_chunk.new(payload: {
        "responseId" => "gem-stream",
        "candidates" => [{ "content" => { "parts" => [{ "text" => "Gemini" }] }, "finishReason" => "STOP" }]
      }, text_mode: :cumulative)
    ])
    configure_external_provider(:gemini, GeminiClient.new(streams))
    events = []

    response = stream(provider: :gemini) { |event| events << event }

    assert_equal "Gemini", response.text
    assert_equal %w[Gem ini], events.filter_map(&:text_delta)
  end

  def test_gemini_stream_preserves_repeated_prefix_sharing_deltas
    streams = GeminiStreams.new([
      { "candidates" => [{ "content" => { "parts" => [{ "text" => "ha" }] } }] },
      { "candidates" => [{ "content" => { "parts" => [{ "text" => "ha" }] }, "finishReason" => "STOP" }] }
    ])
    configure_external_provider(:gemini, GeminiClient.new(streams))
    events = []

    response = stream(provider: :gemini) { |event| events << event }

    assert_equal "haha", response.text
    assert_equal %w[ha ha], events.filter_map(&:text_delta)
  end

  def test_gemini_sse_parser_handles_fragmented_multiline_crlf_events
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret", timeout: 1)
    response = FragmentedResponse.new(
      "data: {\"responseId\":\"one\",\r\n",
      "data: \"candidates\":[]}\r\n\r\ndata: [DO",
      "NE]\r\n\r\n"
    )
    payloads = []

    client.send(:parse_sse, response) { |payload| payloads << payload }

    assert_equal [{ "responseId" => "one", "candidates" => [] }], payloads
  end

  def test_gemini_sse_parser_normalizes_malformed_trailing_payload
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret", timeout: 1)
    response = FragmentedResponse.new("data: {\"responseId\":")

    error = assert_raises(RecordingStudioAI::ProviderClients::Gemini::HttpError) do
      client.send(:parse_sse, response) { flunk "malformed payload must not be yielded" }
    end

    assert_equal 502, error.status
    assert_equal "invalid_stream_payload", error.code
  end

  def test_invalid_structured_stream_discards_buffered_deltas_and_emits_one_terminal_error
    provider = StreamProvider.new([
      [stream_event(:text_delta, text_delta: '{"wrong":true}')],
      RecordingStudioAI::Providers::Result.new(text: '{"wrong":true}')
    ])
    configure_provider(provider, capabilities: %i[generation streaming structured_output])
    events = []
    schema = {
      "type" => "object",
      "properties" => { "summary" => { "type" => "string" } },
      "required" => ["summary"]
    }

    response = RecordingStudioAI.stream(**stream_arguments, schema: schema) { |event| events << event }

    refute response.success?
    assert_equal ["error"], events.map(&:type)
    assert_equal "schema_validation", events.last.error.category
    assert_equal "failed", RecordingStudioAI::Attempt.first.status
  end

  def test_stream_custom_tool_lifecycle_and_continuation
    register_tool
    tool_call = RecordingStudioAI::Providers::ToolCall.new(
      provider_tool_call_id: "call-1",
      key: "lookup_topic",
      arguments: { topic: "Rails" }
    )
    provider = StreamProvider.new(
      [[], RecordingStudioAI::Providers::Result.new(tool_calls: [tool_call], finish_reason: "tool_calls")],
      [[stream_event(:text_delta, text_delta: "Found")], RecordingStudioAI::Providers::Result.new(text: "Found")]
    )
    configure_provider(provider, capabilities: %i[generation streaming custom_tools])
    events = []

    completion_transaction_depths = []
    response = stream(custom_tools: [{ key: :lookup_topic, version: 1 }]) do |event|
      events << event
      if event.type == "custom_tool_completed"
        completion_transaction_depths << ActiveRecord::Base.connection.open_transactions
      end
    end

    assert response.success?
    assert_equal %w[custom_tool_requested custom_tool_started custom_tool_completed text_delta completed], events.map(&:type)
    assert_equal %w[primary continuation], response.attempts.map(&:kind)
    assert_equal "completed", RecordingStudioAI::CustomToolInvocation.first.status
    assert_equal [0], completion_transaction_depths
  end

  def test_structured_stream_supports_custom_tool_continuation
    register_tool
    tool_call = RecordingStudioAI::Providers::ToolCall.new(
      provider_tool_call_id: "call-schema",
      key: "lookup_topic",
      arguments: { topic: "Rails" }
    )
    provider = StreamProvider.new(
      [[], RecordingStudioAI::Providers::Result.new(tool_calls: [tool_call], finish_reason: "tool_calls")],
      [
        [stream_event(:text_delta, text_delta: '{"summary":"Found"}')],
        RecordingStudioAI::Providers::Result.new(text: '{"summary":"Found"}')
      ]
    )
    configure_provider(provider, capabilities: %i[generation streaming structured_output custom_tools])
    schema = {
      "type" => "object",
      "properties" => { "summary" => { "type" => "string" } },
      "required" => ["summary"]
    }
    events = []

    response = RecordingStudioAI.stream(
      **stream_arguments(custom_tools: [{ key: :lookup_topic, version: 1 }]),
      schema: schema
    ) { |event| events << event }

    assert response.success?
    assert_equal({ "summary" => "Found" }, response.structured_data)
    assert_equal %w[custom_tool_requested custom_tool_started custom_tool_completed text_delta completed], events.map(&:type)
  end

  def test_consumer_exception_on_tool_completion_terminalizes_continuation
    register_tool
    tool_call = RecordingStudioAI::Providers::ToolCall.new(
      provider_tool_call_id: "call-disconnect",
      key: "lookup_topic",
      arguments: { topic: "Rails" }
    )
    provider = StreamProvider.new(
      [[], RecordingStudioAI::Providers::Result.new(tool_calls: [tool_call], finish_reason: "tool_calls")],
      [[stream_event(:text_delta, text_delta: "unused")], RecordingStudioAI::Providers::Result.new(text: "unused")]
    )
    configure_provider(provider, capabilities: %i[generation streaming custom_tools])

    error = assert_raises(RuntimeError) do
      stream(custom_tools: [{ key: :lookup_topic, version: 1 }]) do |event|
        raise "consumer disconnected" if event.type == "custom_tool_completed"
      end
    end

    assert_equal "consumer disconnected", error.message
    assert_equal "cancelled", RecordingStudioAI::Run.first.status
    continuation = RecordingStudioAI::Attempt.find_by!(kind: "continuation")
    assert_equal "cancelled", continuation.status
    assert_equal "stream_cancelled", continuation.error_code
    assert_empty RecordingStudioAI::Attempt.where(status: "running")
    assert_empty RecordingStudioAI::CustomToolInvocation.where(status: %w[requested authorized running])
  end

  def test_stream_payload_contracts_reject_non_serializable_content
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::StreamEvent.new(type: :text_delta, text_delta: Object.new)
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::Result.new(text: Object.new)
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Providers::Result.new(structured_data: Object.new)
    end
  end

  private

  def stream_event(type, **attributes)
    RecordingStudioAI::Providers::StreamEvent.new(type: type, **attributes)
  end

  def stream(provider: nil, custom_tools: [], &block)
    RecordingStudioAI.stream(**stream_arguments(provider: provider, custom_tools: custom_tools), &block)
  end

  def stream_arguments(provider: nil, custom_tools: [])
    {
      prompt: "Stream this",
      provider: provider,
      custom_tools: custom_tools,
      root_recording: @root_recording,
      initiator: @initiator
    }
  end

  def configure_provider(provider, capabilities: %i[generation streaming])
    configuration = RecordingStudioAI.configuration
    configuration.providers = { test: provider }
    configuration.profiles[:medium] = [
      { provider: :test, model: "stream-model", capabilities: capabilities }
    ]
  end

  def configure_external_provider(provider, client)
    configuration = RecordingStudioAI.configuration
    configuration.public_send("#{provider}_client=", client)
    configuration.allowed_provider_overrides = [provider]
    configuration.profiles[:medium] = [
      { provider: provider, model: "stream-model", capabilities: %i[generation streaming provider_native_web_search] }
    ]
  end

  def register_tool
    RecordingStudioAI.tools.register(
      key: :lookup_topic,
      version: 1,
      name: "Lookup topic",
      description: "Looks up a topic.",
      use_when: "Facts are needed.",
      do_not_use_when: "No lookup is needed.",
      parameters: [{ name: :topic, type: :string, required: true, description: "Topic." }],
      returns: "A serializable result.",
      cost: :low,
      latency: :fast,
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "Topics.lookup",
      executor: ->(arguments, _context) { { result: arguments.fetch("topic") } }
    )
  end

  def bootstrap_external_recording_studio_table
    ActiveRecord::Base.connection.create_table(:recording_studio_recordings) do |table|
      table.timestamps
    end
  end

  def create_recording_id
    ActiveRecord::Base.connection.insert(
      "INSERT INTO recording_studio_recordings (created_at, updated_at) VALUES (CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)"
    )
  end
end
