# frozen_string_literal: true

require "test_helper"
require "base64"
require "json"
require "stringio"

class ProviderGapCoverageTest < RecordingStudioAI::Test::IsolatedCase
  class StatusError < StandardError
    attr_reader :status, :code

    def initialize(status:, code: "invalid_api_key")
      @status = status
      @code = code
      super("secret provider payload sk-live")
    end
  end

  class HashLikeArguments
    def to_h
      { "limit" => 4 }
    end
  end

  class RaisingJson
    def to_json(*)
      raise TypeError, "cannot encode secret sk-live"
    end

    def to_s
      "raising-json"
    end
  end

  BatchDouble = Struct.new(:provider_batch_id, :status, :batch_items)
  ItemDouble = Struct.new(:reference, :metadata)

  class GeminiModels
    attr_reader :requests
    attr_accessor :response, :chunks, :error, :stream_error

    def initialize
      @requests = []
      @chunks = []
      @response = {
        "responseId" => "gem-1",
        "candidates" => [{
          "finishReason" => "STOP",
          "content" => { "parts" => [{ "text" => "ok" }] }
        }]
      }
    end

    def generate_content(**request)
      requests << request
      raise error if error

      response
    end

    def stream_generate_content(**request)
      requests << request
      raise stream_error if stream_error

      chunks
    end
  end

  class GeminiClient
    attr_reader :models, :batch_requests, :cancelled_name
    attr_accessor :batch_response, :get_response, :batch_error, :get_error, :cancel_error

    def initialize
      @models = GeminiModels.new
      @batch_requests = []
    end

    def batch_generate_content(**request)
      batch_requests << request
      raise batch_error if batch_error

      batch_response || { "name" => "batches/1", "metadata" => { "state" => "PENDING" } }
    end

    def get_batch(name)
      raise get_error if get_error

      get_response || { "name" => name, "metadata" => { "state" => "SUCCEEDED" } }
    end

    def cancel_batch(name)
      @cancelled_name = name
      raise cancel_error if cancel_error

      {}
    end
  end

  class OpenAIResponses
    attr_reader :requests
    attr_accessor :response, :events, :error

    def initialize
      @requests = []
      @events = []
      @response = { id: "resp-1", output_text: "ok", status: "completed" }
    end

    def create(**request)
      requests << request
      raise error if error

      response
    end

    def stream(**request)
      requests << request
      raise error if error

      events
    end
  end

  class OpenAIFiles
    attr_reader :uploaded
    attr_accessor :error, :body

    def create(file:, purpose:)
      @uploaded = file
      @purpose = purpose
      raise error if error

      Struct.new(:id).new("file-1")
    end

    def content(_file_id)
      StringIO.new(body.to_s)
    end
  end

  class OpenAIBatches
    attr_reader :cancelled_id
    attr_accessor :response, :error, :cancel_error

    def create(**)
      raise error if error

      response || { id: "batch-1", status: "validating" }
    end

    def retrieve(*)
      raise error if error

      response
    end

    def cancel(batch_id)
      @cancelled_id = batch_id
      raise cancel_error if cancel_error

      { id: batch_id, status: "cancelled" }
    end
  end

  OpenAIClient = Struct.new(:responses, :files, :batches)

  class HostedStream
    attr_reader :closed

    def initialize(events)
      @events = events
      @closed = false
    end

    def each(&)
      @events.each(&)
    end

    def close
      @closed = true
    end
  end

  class HostedEvents
    def initialize(sessions)
      @sessions = sessions
    end

    def stream_streaming(_session_id)
      @sessions.stream
    end
  end

  class HostedTurns
    attr_accessor :turn

    def retrieve(turn_id, session_id:)
      turn || { id: turn_id, session_id: session_id, status: "completed" }
    end

    def list(*_args, **_kwargs)
      Struct.new(:data).new([])
    end
  end

  class HostedItems
    def list(*_args, **_kwargs)
      Struct.new(:data, :next_page?).new([], false)
    end
  end

  class HostedSessions
    attr_reader :events, :turns, :items
    attr_accessor :stream

    def initialize(turns)
      @turns = turns
      @events = HostedEvents.new(self)
      @items = HostedItems.new
      @stream = HostedStream.new([])
    end

    def retrieve(session_id)
      { id: session_id, status: "idle", agent: { model: "gpt-test" }, required_actions: [] }
    end
  end

  def setup
    super
    isolate_configuration!
  end

  def test_gemini_http_client_returns_itself_and_posts_keyed_batches
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    assert_same client, client.models

    bodies = ['{"name":"batches/job-1","state":"PENDING"}', ""]
    captured = []
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured << request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, bodies.shift)
      response
    end

    parsed = nil
    empty = nil
    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      parsed = client.batch_generate_content(
        model: "gemini-test",
        requests: [{ key: "item-1", contents: [{ role: "user", parts: [{ text: "hello" }] }] }]
      )
      empty = client.batch_generate_content(
        model: "gemini-test",
        requests: [{ key: "item-2", contents: [{ role: "user", parts: [{ text: "again" }] }] }]
      )
    end

    assert_equal "batches/job-1", parsed.fetch("name")
    assert_equal({}, empty)
    posted = JSON.parse(captured.first.body)
    entry = posted.dig("batch", "input_config", "requests", "requests", 0)
    assert_equal "item-1", entry.dig("metadata", "key")
    assert_equal "hello", entry.dig("request", "contents", 0, "parts", 0, "text")
    assert_equal "secret-key", captured.first["x-goog-api-key"]
    assert_includes captured.first.path, "gemini-test:batchGenerateContent"
    refute_includes captured.first.body, "secret-key"
    second = JSON.parse(captured.last.body)
    assert_equal "item-2", second.dig("batch", "input_config", "requests", "requests", 0, "metadata", "key")
  end

  def test_gemini_http_client_camelizes_parts_and_passes_unknown_tools_through
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    captured = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured = request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, '{"responseId":"gem-parts"}')
      response
    end

    result = Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      client.generate_content(
        model: "gemini-test",
        contents: [{
          role: "user",
          parts: [
            { function_call: { name: "lookup", args: { "q" => "x" } } },
            { function_response: { name: "lookup", response: { "ok" => true } } },
            { inline_data: { mime_type: "image/png", data: "abc123" } }
          ]
        }],
        config: {
          tools: [
            { google_search: {} },
            { function_declarations: [{ name: "lookup", description: "Look up.",
                                        parameters: { "type" => "object" } }] },
            { code_execution: { "language" => "python" } }
          ]
        }
      )
    end

    assert_equal "gem-parts", result.fetch("responseId")
    body = JSON.parse(captured.body)
    parts = body.dig("contents", 0, "parts")
    assert_equal({ "functionCall" => { "name" => "lookup", "args" => { "q" => "x" } } }, parts[0])
    assert_equal({ "functionResponse" => { "name" => "lookup", "response" => { "ok" => true } } }, parts[1])
    assert_equal({ "inlineData" => { "mimeType" => "image/png", "data" => "abc123" } }, parts[2])
    assert_equal({}, body.dig("tools", 0, "googleSearch"))
    assert_equal "lookup", body.dig("tools", 1, "functionDeclarations", 0, "name")
    assert_equal({ "code_execution" => { "language" => "python" } }, body.dig("tools", 2))
    refute(body["tools"].any? { |tool| tool.key?("codeExecution") })
  end

  def test_gemini_http_client_non_json_error_hides_the_raw_body
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    http = Object.new
    http.define_singleton_method(:request) do |_request|
      response = Net::HTTPBadRequest.new("1.1", "400", "Bad Request")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, "<html>RAW-BODY-SECRET-sk-live</html>")
      response
    end

    error = Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      assert_raises(RecordingStudioAI::ProviderClients::Gemini::HttpError) do
        client.generate_content(model: "gemini-test", contents: [{ role: "user", parts: [{ text: "hi" }] }])
      end
    end

    assert_equal 400, error.status
    assert_nil error.code
    assert_nil error.provider_message
    assert_equal "Gemini request failed", error.message
    refute_includes error.message, "RAW-BODY-SECRET"
    refute_includes error.message, "sk-live"
  end

  def test_gemini_generate_expected_error_is_a_failed_result_and_unexpected_errors_propagate
    client = GeminiClient.new
    provider = gemini_provider(client)
    client.models.error = StatusError.new(status: 429, code: "rate_limit_exceeded")

    result = provider.generate(request: generation_request, candidate: candidate(:gemini))

    refute result.success?
    assert_equal "rate_limit", result.error.category
    assert_equal "http_429", result.error.code
    assert_equal "rate_limit_exceeded", result.error.provider_code
    refute_secret result.error.message

    boom = RuntimeError.new("secret unexpected sk-live")
    client.models.error = boom
    raised = assert_raises(RuntimeError) do
      provider.generate(request: generation_request, candidate: candidate(:gemini))
    end
    assert_same boom, raised
  end

  def test_gemini_generate_safety_finish_is_content_policy_and_missing_candidate_is_invalid
    client = GeminiClient.new
    provider = gemini_provider(client)
    client.models.response = {
      "candidates" => [{ "finishReason" => "SAFETY", "content" => { "parts" => [{ "text" => "secret sk-live" }] } }]
    }

    blocked = provider.generate(request: generation_request, candidate: candidate(:gemini))

    refute blocked.success?
    assert_equal "safety", blocked.finish_reason
    assert_equal "content_policy", blocked.error.category
    assert_equal "blocked", blocked.error.code
    assert_equal "Provider blocked the response under its content policy.", blocked.error.message
    refute_secret blocked.error.message

    client.models.response = { "candidates" => [] }
    missing = provider.generate(request: generation_request, candidate: candidate(:gemini))

    refute missing.success?
    assert_equal "invalid_response", missing.error.category
    assert_equal "missing_candidate", missing.error.code
    assert_equal "Provider returned no generation candidate.", missing.error.message
  end

  def test_gemini_generate_rejects_tool_call_arguments_that_fail_the_contract
    client = GeminiClient.new
    provider = gemini_provider(client)
    client.models.response = {
      "responseId" => "gem-tool",
      "candidates" => [{
        "finishReason" => "STOP",
        "content" => { "parts" => [{ "functionCall" => { "name" => "lookup_topic", "args" => "not-a-hash" } }] }
      }]
    }

    error = assert_raises(JSON::ParserError) do
      provider.generate(request: generation_request, candidate: candidate(:gemini))
    end

    assert_includes error.message, "Hash arguments"
    refute_secret error.message
  end

  def test_gemini_stream_emits_duplicate_tool_calls_once_and_keeps_chunk_errors
    client = GeminiClient.new
    provider = gemini_provider(client)
    chunk = {
      "responseId" => "gem-stream",
      "candidates" => [{
        "finishReason" => "STOP",
        "content" => {
          "parts" => [
            { "text" => "A" },
            { "functionCall" => { "name" => "lookup_topic", "args" => { "topic" => "rails" } } }
          ]
        }
      }]
    }
    client.models.chunks = [chunk, chunk]
    events = []

    result = provider.stream(request: generation_request, candidate: candidate(:gemini)) { |event| events << event }

    assert result.success?
    assert_equal "AA", result.text
    assert_equal %w[A A], events.map(&:text_delta)
    assert_equal 1, result.tool_calls.length
    assert_equal "lookup_topic", result.tool_calls.first.key
    assert_equal({ "topic" => "rails" }, result.tool_calls.first.arguments)
    assert_equal "gem-stream:1", result.tool_calls.first.provider_tool_call_id

    client.models.chunks = [
      { "candidates" => [{ "finishReason" => "STOP", "content" => { "parts" => [{ "text" => "Hi" }] } }] },
      { "candidates" => [{ "finishReason" => "SAFETY", "content" => { "parts" => [{ "text" => "!" }] } }] }
    ]
    errored = provider.stream(request: generation_request, candidate: candidate(:gemini)) { |_event| }

    refute errored.success?
    assert_equal "Hi!", errored.text
    assert_equal "safety", errored.finish_reason
    assert_equal "content_policy", errored.error.category
    assert_equal "blocked", errored.error.code
  end

  def test_gemini_stream_expected_error_is_a_failed_result_and_unexpected_errors_propagate
    client = GeminiClient.new
    provider = gemini_provider(client)
    client.models.stream_error = StatusError.new(status: 503, code: "unavailable")
    events = []

    result = provider.stream(request: generation_request, candidate: candidate(:gemini)) { |event| events << event }

    assert_empty events
    refute result.success?
    assert_equal "provider_unavailable", result.error.category
    assert_equal "http_503", result.error.code
    refute_secret result.error.message

    boom = RuntimeError.new("secret unexpected sk-live")
    client.models.stream_error = boom
    raised = assert_raises(RuntimeError) do
      provider.stream(request: generation_request, candidate: candidate(:gemini)) { |_event| }
    end
    assert_same boom, raised
  end

  def test_gemini_batch_methods_return_failed_results_without_leaking_expected_errors
    client = GeminiClient.new
    provider = gemini_provider(client)
    secret = StatusError.new(status: 401, code: "invalid_api_key")
    request = { items: [generation_request.merge(reference: "ref-1")] }
    batch = BatchDouble.new("batches/9", "processing", [])
    client.batch_error = secret

    submitted = provider.submit_batch(request: request, candidate: candidate(:gemini))

    assert_equal "failed", submitted.status
    assert_nil submitted.provider_batch_id
    assert_equal "authentication", submitted.error.category
    assert_equal "http_401", submitted.error.code
    refute_secret submitted.error.message

    client.batch_error = nil
    client.get_error = secret
    refreshed = provider.refresh_batch(batch: batch, candidate: candidate(:gemini))

    assert_equal "processing", refreshed.status
    assert_equal "batches/9", refreshed.provider_batch_id
    assert_equal "authentication", refreshed.error.category
    refute_secret refreshed.error.message

    client.get_error = nil
    client.cancel_error = secret
    cancelled = provider.cancel_batch(batch: batch, candidate: candidate(:gemini))

    assert_equal "batches/9", client.cancelled_name
    assert_equal "processing", cancelled.status
    assert_equal "batches/9", cancelled.provider_batch_id
    refute_secret cancelled.error.message
  end

  def test_gemini_batch_states_map_and_expired_or_failed_batches_carry_errors
    client = GeminiClient.new
    provider = gemini_provider(client)
    batch = BatchDouble.new("batches/1", "processing", [])
    expectations = {
      "PENDING" => ["submitted", nil, nil],
      "RUNNING" => ["processing", nil, nil],
      "SUCCEEDED" => ["completed", nil, nil],
      "FAILED" => %w[failed provider_error batch_failed],
      "CANCELLED" => ["cancelled", nil, nil],
      "EXPIRED" => %w[expired batch_expired batch_expired],
      "MYSTERY" => ["submitted", nil, nil]
    }

    expectations.each do |state, (status, category, code)|
      client.get_response = { "name" => "batches/1", "metadata" => { "state" => state } }
      result = provider.refresh_batch(batch: batch, candidate: candidate(:gemini))

      assert_equal status, result.status, state
      assert_equal state, result.metadata["provider_state"], state
      if code
        assert_equal category, result.error.category, state
        assert_equal code, result.error.code, state
        refute_secret result.error.message
      else
        assert_nil result.error, state
      end
    end

    client.get_response = { "name" => "batches/1", "metadata" => { "state" => "EXPIRED" } }
    expired = provider.refresh_batch(batch: batch, candidate: candidate(:gemini))
    assert_equal "Provider batch expired.", expired.error.message

    client.get_response = { "name" => "batches/1", "metadata" => { "state" => "FAILED" } }
    failed = provider.refresh_batch(batch: batch, candidate: candidate(:gemini))
    assert_equal "Provider batch failed.", failed.error.message
  end

  def test_gemini_batch_item_errors_and_structured_output_parse
    client = GeminiClient.new
    provider = gemini_provider(client)
    batch = BatchDouble.new("batches/1", "processing", [
                              ItemDouble.new("good-json", { "structured_output" => true }),
                              ItemDouble.new("bad-json", { "structured_output" => true }),
                              ItemDouble.new("plain", { "structured_output" => false })
                            ])
    client.get_response = {
      "name" => "batches/1",
      "metadata" => { "state" => "SUCCEEDED" },
      "response" => {
        "dest" => {
          "inlinedResponses" => [
            {
              "metadata" => { "key" => "bad-item" },
              "error" => { "status" => "INTERNAL", "message" => "secret sk-live item" }
            },
            {
              "metadata" => { "key" => "bare-item" },
              "error" => { "message" => "secret sk-live bare" }
            },
            gemini_inline("good-json", '{"answer":1}'),
            gemini_inline("bad-json", "{not-json"),
            gemini_inline("plain", '{"answer":1}')
          ]
        }
      }
    }

    result = provider.refresh_batch(batch: batch, candidate: candidate(:gemini))
    items = result.items.index_by(&:reference)

    assert_equal "failed", items.fetch("bad-item").status
    assert_equal "provider_error", items.fetch("bad-item").error.category
    assert_equal "INTERNAL", items.fetch("bad-item").error.code
    assert_equal "Provider batch item failed.", items.fetch("bad-item").error.message
    refute_secret items.fetch("bad-item").error.message
    assert_equal "batch_item_failed", items.fetch("bare-item").error.code
    assert_equal "completed", items.fetch("good-json").status
    assert_equal({ "answer" => 1 }, items.fetch("good-json").structured_data)
    assert_equal "completed", items.fetch("bad-json").status
    assert_nil items.fetch("bad-json").structured_data
    assert_equal "completed", items.fetch("plain").status
    assert_nil items.fetch("plain").structured_data
    assert_equal '{"answer":1}', items.fetch("plain").text
  end

  def test_gemini_message_attachments_append_to_the_last_user_turn_only
    client = GeminiClient.new
    provider = gemini_provider(client)
    encoded = Base64.strict_encode64("file-bytes")

    attached = provider.generate(
      request: message_request(
        [{ role: "user", content: "Question" }, { role: "assistant", content: "Earlier" }],
        [file_attachment]
      ),
      candidate: candidate(:gemini)
    )
    untouched = provider.generate(
      request: message_request([{ role: "assistant", content: "Earlier" }], [file_attachment]),
      candidate: candidate(:gemini)
    )

    assert attached.success?
    assert untouched.success?
    with_user, without_user = client.models.requests.map { |request| request.fetch(:contents) }
    assert_equal "user", with_user[0][:role]
    assert_equal [{ text: "Question" }, { inline_data: { mime_type: "text/plain", data: encoded } }],
                 with_user[0][:parts]
    assert_equal [{ role: "model", parts: [{ text: "Earlier" }] }], with_user[1..]
    assert_equal [{ role: "model", parts: [{ text: "Earlier" }] }], without_user
  end

  def test_openai_expected_provider_errors_become_failed_results
    client = openai_client
    provider = openai_provider(client)
    secret = StatusError.new(status: 401, code: "invalid_api_key")
    client.responses.error = secret

    generated = provider.generate(request: generation_request, candidate: candidate(:openai))
    streamed_events = []
    streamed = provider.stream(request: generation_request, candidate: candidate(:openai)) do |event|
      streamed_events << event
    end

    [generated, streamed].each do |result|
      refute result.success?
      assert_equal "authentication", result.error.category
      assert_equal "http_401", result.error.code
      refute_secret result.error.message
    end
    assert_empty streamed_events

    client.responses.error = nil
    client.files.error = secret
    submitted = provider.submit_batch(
      request: { items: [generation_request.merge(reference: "ref-1")] },
      candidate: candidate(:openai)
    )
    assert_equal "failed", submitted.status
    assert_nil submitted.provider_batch_id
    assert_equal "authentication", submitted.error.category
    refute_secret submitted.error.message

    client.files.error = nil
    batch = BatchDouble.new("batch-9", "processing", [])
    client.batches.error = secret
    refreshed = provider.refresh_batch(batch: batch, candidate: candidate(:openai))
    assert_equal "processing", refreshed.status
    assert_equal "batch-9", refreshed.provider_batch_id
    refute_secret refreshed.error.message

    client.batches.error = nil
    client.batches.cancel_error = secret
    cancelled = provider.cancel_batch(batch: batch, candidate: candidate(:openai))
    assert_equal "batch-9", client.batches.cancelled_id
    assert_equal "processing", cancelled.status
    assert_equal "batch-9", cancelled.provider_batch_id
    refute_secret cancelled.error.message
  end

  def test_openai_generate_unexpected_error_propagates
    client = openai_client
    provider = openai_provider(client)
    boom = RuntimeError.new("secret unexpected sk-live")
    client.responses.error = boom

    raised = assert_raises(RuntimeError) do
      provider.generate(request: generation_request, candidate: candidate(:openai))
    end

    assert_same boom, raised
  end

  def test_openai_stream_without_a_terminal_completion_is_invalid
    client = openai_client
    provider = openai_provider(client)
    client.responses.events = [{ type: "response.output_text.delta", delta: "Partial" }]
    events = []

    result = provider.stream(request: generation_request, candidate: candidate(:openai)) { |event| events << event }

    assert_equal ["Partial"], events.map(&:text_delta)
    refute result.success?
    assert_equal "invalid_response", result.error.category
    assert_equal "missing_stream_completion", result.error.code
    assert_equal "Provider stream ended without a completed response.", result.error.message
  end

  def test_openai_stream_error_codes_map_to_neutral_categories
    client = openai_client
    provider = openai_provider(client)
    mappings = {
      "rate_limit_exceeded" => ["rate_limit", "rate_limit_exceeded", true],
      "timeout" => ["timeout", "timeout", true],
      "connection_error" => ["connection", "connection_error", true],
      "server_error" => ["provider_unavailable", "server_error", true],
      "upstream_503" => ["provider_unavailable", "upstream_503", true],
      "invalid_prompt" => ["provider_error", "invalid_prompt", false]
    }

    mappings.each do |code, (category, expected_code, retryable)|
      client.responses.events = [{ type: "error", error: { code: code, message: "secret sk-live #{code}" } }]
      result = provider.stream(request: generation_request, candidate: candidate(:openai)) { |_event| }

      assert_equal category, result.error.category, code
      assert_equal expected_code, result.error.code, code
      assert_equal retryable, result.error.retryable?, code
      refute_secret result.error.message
    end

    client.responses.events = [{ type: "error", error: { message: "secret sk-live" } }]
    missing_code = provider.stream(request: generation_request, candidate: candidate(:openai)) { |_event| }
    assert_equal "provider_error", missing_code.error.category
    assert_equal "failed", missing_code.error.code
    refute missing_code.error.retryable?
    refute_secret missing_code.error.message
  end

  def test_openai_refresh_maps_non_success_statuses_and_request_counts
    client = openai_client
    provider = openai_provider(client)
    batch = BatchDouble.new("batch-1", "processing", [])
    cases = [
      { status: "expired", expected: "expired", category: "batch_expired", code: "batch_expired" },
      { status: "cancelled", expected: "cancelled" },
      { status: "failed", expected: "failed", category: "provider_error", code: "batch_failed" },
      { status: "in_progress", expected: "processing", counts: { total: 4, completed: 3, failed: 1 } },
      { status: "mystery", expected: "submitted" }
    ]

    cases.each do |example|
      payload = { id: "batch-1", status: example.fetch(:status) }
      payload[:request_counts] = example[:counts] if example[:counts]
      client.batches.response = payload
      result = provider.refresh_batch(batch: batch, candidate: candidate(:openai))

      assert_equal example.fetch(:expected), result.status, example.fetch(:status)
      if example[:code]
        assert_equal example.fetch(:category), result.error.category, example.fetch(:status)
        assert_equal example.fetch(:code), result.error.code, example.fetch(:status)
      else
        assert_nil result.error, example.fetch(:status)
      end
      if example[:counts]
        assert_equal({ "total" => 4, "completed" => 3, "failed" => 1 }, result.metadata["request_counts"])
      end
    end

    client.batches.response = { id: "batch-1", status: "expired" }
    expired = provider.refresh_batch(batch: batch, candidate: candidate(:openai))
    assert_equal "Provider batch expired.", expired.error.message
    client.batches.response = { id: "batch-1", status: "failed" }
    failed = provider.refresh_batch(batch: batch, candidate: candidate(:openai))
    assert_equal "Provider batch failed.", failed.error.message
  end

  def test_openai_batch_items_fail_on_provider_errors_and_drop_malformed_structured_json
    client = openai_client
    provider = openai_provider(client)
    batch = BatchDouble.new("batch-1", "processing", [
                              ItemDouble.new("good-json", { "structured_output" => true }),
                              ItemDouble.new("bad-json", { "structured_output" => true })
                            ])
    client.batches.response = { id: "batch-1", status: "completed", output_file_id: "out-1" }
    client.files.body = [
      jsonl(custom_id: "bad-item", response: {
              status_code: 400, request_id: "req-bad",
              body: { error: { code: "invalid_prompt", message: "secret sk-live item" } }
            }),
      jsonl(custom_id: "bare-item", response: { status_code: 500, request_id: "req-bare", body: {} }),
      jsonl(custom_id: "good-json", response: {
              status_code: 200, request_id: "req-good",
              body: { id: "resp-good", status: "completed", output_text: '{"answer":true}' }
            }),
      jsonl(custom_id: "bad-json", response: {
              status_code: 200, request_id: "req-bad-json",
              body: { id: "resp-bad", status: "completed", output_text: "{not-json" }
            })
    ].join

    result = provider.refresh_batch(batch: batch, candidate: candidate(:openai))
    items = result.items.index_by(&:reference)

    assert_equal "failed", items.fetch("bad-item").status
    assert_equal "invalid_prompt", items.fetch("bad-item").error.code
    assert_equal "400", items.fetch("bad-item").error.provider_code
    assert_equal "Provider batch item failed.", items.fetch("bad-item").error.message
    refute_secret items.fetch("bad-item").error.message
    assert_equal "batch_item_failed", items.fetch("bare-item").error.code
    assert_equal "500", items.fetch("bare-item").error.provider_code
    assert_equal({ "answer" => true }, items.fetch("good-json").structured_data)
    assert_equal "completed", items.fetch("good-json").status
    assert_nil items.fetch("bad-json").structured_data
    assert_equal "completed", items.fetch("bad-json").status
    assert_equal "{not-json", items.fetch("bad-json").text
  end

  def test_openai_oversized_tool_arguments_fail_the_result
    RecordingStudioAI.configuration.maximum_custom_tool_arguments_size = 8
    client = openai_client
    provider = openai_provider(client)
    raw = '{"note":"sk-live-argument-payload"}'
    client.responses.response = {
      id: "resp-tool",
      output_text: "",
      status: "completed",
      output: [{ type: "function_call", call_id: "call-1", name: "lookup_topic", arguments: raw }]
    }

    result = provider.generate(request: generation_request, candidate: candidate(:openai))

    refute result.success?
    assert_equal "invalid_response", result.error.category
    assert_equal "invalid_tool_arguments", result.error.code
    assert_equal "Provider returned invalid custom-tool arguments.", result.error.message
    refute_includes result.error.message, "sk-live-argument-payload"
    refute_includes result.error.message, "maximum_custom_tool_arguments_size"
  end

  def test_openai_message_attachments_land_on_the_last_user_message
    client = openai_client
    provider = openai_provider(client)
    encoded = Base64.strict_encode64("file-bytes")

    with_user = provider.generate(
      request: message_request(
        [{ role: "user", content: "Question" }, { role: "assistant", content: "Earlier" }],
        [file_attachment]
      ),
      candidate: candidate(:openai)
    )
    without_user = provider.generate(
      request: message_request([{ role: "assistant", content: "Earlier" }], [file_attachment]),
      candidate: candidate(:openai)
    )

    assert with_user.success?
    assert without_user.success?
    attached, unchanged = client.responses.requests.map { |request| request.fetch(:input) }
    assert_equal [
      { type: "input_text", text: "Question" },
      { type: "input_file", filename: "notes.txt", file_data: "data:text/plain;base64,#{encoded}" }
    ], attached[0][:content]
    assert_equal "Earlier", attached[1][:content]
    assert_equal "assistant", attached[1][:role]
    assert_equal [{ role: "assistant", content: "Earlier" }], unchanged
  end

  def test_openai_generate_builds_a_client_from_the_api_key_without_a_network_call
    require "openai"
    fake = openai_client
    fake.responses.response = { id: "resp-built", output_text: "built", status: "completed" }
    configuration = RecordingStudioAI.configuration
    configuration.openai_api_key = "test-key"
    configuration.openai_client = nil
    provider = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
    seen = nil

    result = Net::HTTP.stub(:start, ->(*, **) { flunk "OpenAI generate opened a network connection" }) do
      OpenAI::Client.stub(:new, lambda { |**kwargs, &_|
        seen = kwargs
        fake
      }) do
        provider.generate(request: generation_request, candidate: candidate(:openai))
      end
    end

    assert_equal "built", result.text
    assert_equal({ api_key: "test-key" }, seen)
    assert_equal "openai-test", fake.responses.requests.first.fetch(:model)
    assert_equal false, fake.responses.requests.first.fetch(:store)
  end

  def test_hosted_agent_recover_reports_turn_errors_by_session_failure_category
    build_hosted_adapter
    cases = [
      [{ status: "failed", error: { code: "session_expired", message: "secret sk-live" } },
       "failed", "invalid_session", "session_expired", "Hosted agent session is invalid or expired."],
      [{ status: "cancelled", error: { code: "rate_limit_exceeded", message: "secret sk-live" } },
       "cancelled", "cancelled", "rate_limit_exceeded", "Hosted agent turn was cancelled."],
      [{ status: "expired", error: { code: "model_not_found", message: "secret sk-live" } },
       "expired", "unsupported_model", "model_not_found", "Provider model is not supported for hosted agents."],
      [{ status: "failed", error: { code: "rate_limit_exceeded", message: "secret sk-live" } },
       "failed", "rate_limit", "rate_limit_exceeded", "Provider rate limit exceeded."],
      [{ status: "expired" }, "expired", "provider_error", "expired", "Provider request failed."]
    ]

    cases.each do |turn, status, category, code, message|
      @turns.turn = { id: "turn_1", status: status }.merge(turn)
      recovery = @adapter.recover_hosted_agent_session(provider_session_id: "sess_1", provider_turn_id: "turn_1")

      assert_equal "sess_1", recovery.session.provider_session_id
      assert_equal status, recovery.turn.status
      assert_equal "turn_1", recovery.turn.provider_turn_id
      assert_equal category, recovery.turn.error.category
      assert_equal code, recovery.turn.error.code
      assert_equal message, recovery.turn.error.message
      refute recovery.turn.error.retryable?
      refute_secret recovery.turn.error.message
      assert_empty recovery.tool_calls
    end
  end

  def test_hosted_agent_stream_events_carry_neutral_errors
    build_hosted_adapter
    failed = collect_hosted_events([
                                     {
                                       type: "agent.session.turn.failed",
                                       turn_id: "turn_1",
                                       error: { code: "session_expired", message: "secret sk-live" }
                                     }
                                   ]).first
    assert_equal "failed", failed.type
    assert_nil failed.text_delta
    assert_equal "invalid_session", failed.error.category
    assert_equal "session_expired", failed.error.code
    assert_equal "Hosted agent session is invalid or expired.", failed.error.message
    assert_equal "turn_1", failed.metadata["provider_turn_id"]
    refute_secret failed.error.message

    environment = collect_hosted_events([
                                          {
                                            type: "agent.session.environment.failed",
                                            error: { code: "model_not_found", message: "secret sk-live" }
                                          }
                                        ]).first
    assert_equal "failed", environment.type
    assert_equal "unsupported_model", environment.error.category
    assert_equal "Provider model is not supported for hosted agents.", environment.error.message

    rate_limited = collect_hosted_events([
                                           { type: "error",
                                             error: { code: "rate_limit_exceeded", message: "secret sk-live" } }
                                         ]).first
    assert_equal "failed", rate_limited.type
    assert_equal "rate_limit", rate_limited.error.category
    assert_equal "Provider rate limit exceeded.", rate_limited.error.message

    generic = collect_hosted_events([
                                      { type: "agent.session.failed",
                                        error: { code: "internal_error", message: "secret sk-live" } }
                                    ]).first
    assert_equal "provider_error", generic.error.category
    assert_equal "internal_error", generic.error.code
    assert_equal "Provider request failed.", generic.error.message

    cancelled = collect_hosted_events([{ type: "agent.session.turn.cancelled", turn_id: "turn_9" }]).first
    assert_equal "cancelled", cancelled.type
    assert_equal "cancelled", cancelled.error.category
    assert_equal "cancelled", cancelled.error.code
    assert_equal "Hosted agent turn was cancelled.", cancelled.error.message
    assert_equal "turn_9", cancelled.metadata["provider_turn_id"]
  end

  def test_hosted_agent_tool_arguments_that_are_not_json_objects
    build_hosted_adapter
    opaque = RaisingJson.new
    events = collect_hosted_events([
                                     {
                                       type: "agent.session.requires_action",
                                       session: {
                                         required_actions: [
                                           function_action("call_bad", "{not-json"),
                                           function_action("call_nil", nil),
                                           function_action("call_list", [1]),
                                           function_action("call_infinity", Float::INFINITY),
                                           function_action("call_opaque", opaque),
                                           function_action("call_hashlike", HashLikeArguments.new)
                                         ]
                                       }
                                     }
                                   ])

    assert_equal ["tool_calls"], events.map(&:type)
    calls = events.first.tool_calls.index_by(&:call_id)
    assert_unparsed calls.fetch("call_bad"), "{not-json"
    assert_unparsed calls.fetch("call_nil"), ""
    assert_unparsed calls.fetch("call_list"), "[1]"
    assert_unparsed calls.fetch("call_infinity"), "Infinity"
    assert_unparsed calls.fetch("call_opaque"), "raising-json"
    parsed = calls.fetch("call_hashlike")
    assert_equal({ "limit" => 4 }, parsed.arguments)
    assert_nil parsed.arguments_error
    assert_nil parsed.raw_arguments
  end

  private

  def gemini_provider(client)
    configuration = RecordingStudioAI.configuration
    configuration.gemini_client = client
    RecordingStudioAI::Providers::Gemini.new(configuration: configuration)
  end

  def openai_client
    OpenAIClient.new(OpenAIResponses.new, OpenAIFiles.new, OpenAIBatches.new)
  end

  def openai_provider(client)
    configuration = RecordingStudioAI.configuration
    configuration.openai_client = client
    RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
  end

  def candidate(provider)
    RecordingStudioAI::Candidate.new(provider: provider, model: "#{provider}-test", capabilities: %i[generation])
  end

  def generation_request
    {
      prompt: "Summarize",
      messages: nil,
      system_instruction: nil,
      attachments: [],
      provider_native_tools: [],
      schema: nil,
      custom_tool_definitions: [],
      custom_tool_history: [],
      temperature: nil,
      max_output_tokens: nil,
      verbosity: nil,
      reasoning_effort: nil
    }
  end

  def message_request(messages, attachments)
    generation_request.merge(prompt: nil, messages: messages, attachments: attachments)
  end

  def file_attachment
    { type: :file, content_type: "text/plain", data: "file-bytes", filename: "notes.txt" }
  end

  def gemini_inline(reference, text)
    {
      "metadata" => { "key" => reference },
      "response" => {
        "responseId" => "resp-#{reference}",
        "candidates" => [{ "finishReason" => "STOP", "content" => { "parts" => [{ "text" => text }] } }]
      }
    }
  end

  def jsonl(payload)
    "#{JSON.generate(payload)}\n"
  end

  def refute_secret(text)
    refute_includes text.to_s, "sk-live"
    refute_includes text.to_s, "RAW-BODY-SECRET"
  end

  def build_hosted_adapter
    @turns = HostedTurns.new
    @sessions = HostedSessions.new(@turns)
    agents = Struct.new(:sessions).new(@sessions)
    beta = Struct.new(:agents).new(agents)
    configuration = RecordingStudioAI.configuration
    configuration.openai_client = Struct.new(:beta).new(beta)
    @adapter = RecordingStudioAI::Providers::OpenAI.new(configuration: configuration)
  end

  def collect_hosted_events(events)
    stream = HostedStream.new(events)
    @sessions.stream = stream
    collected = []
    @adapter.stream_hosted_agent_session(provider_session_id: "sess_1") { |event| collected << event }
    assert stream.closed
    collected
  end

  def function_action(call_id, arguments)
    { type: "function_call", turn_id: "turn_1", call_id: call_id, name: "lookup", arguments: arguments }
  end

  def assert_unparsed(call, raw)
    assert_nil call.arguments
    assert_equal "function call arguments must be a JSON object", call.arguments_error
    assert_equal raw, call.raw_arguments
  end
end

class ProviderGapPersistenceCoverageTest < RecordingStudioAI::Test::PersistenceCase
  Actor = Struct.new(:id)

  class RecordingBatchProvider < RecordingStudioAI::Providers::Base
    attr_reader :submissions, :refreshes
    attr_accessor :submit_result, :refresh_result

    def initialize
      super
      @submissions = []
      @refreshes = []
      @submit_result = RecordingStudioAI::Providers::BatchResult.new(
        status: "submitted", provider_batch_id: "provider-batch-1"
      )
    end

    def submit_batch(request:, candidate:)
      submissions << [request, candidate]
      submit_result
    end

    def refresh_batch(batch:, candidate:)
      refreshes << [batch, candidate]
      refresh_result
    end
  end

  def persistence_schema
    :hardened
  end

  def reset_persistence_columns?
    true
  end

  def setup
    super
    @root = Actor.new(create_recording_id)
    @initiator = Actor.new(77)
    @provider = RecordingBatchProvider.new
    isolate_configuration!(configured_configuration)
  end

  def test_batch_usage_refusal_fails_persisted_records_and_truncates_the_message
    message = "credits exhausted #{'x' * 280}"
    RecordingStudioAI.configuration.credit_prices = { "*" => { input: 1 } }
    RecordingStudioAI.configuration.usage_handler = ->(**) { raise "handler must not run" }
    RecordingStudioAI.configuration.usage_precheck = ->(**) { raise message }

    error = assert_raises(RuntimeError) { submit_item("only") }

    stored = message[0, 255]
    assert_equal message, error.message
    assert_operator message.length, :>, 255
    assert_equal 255, stored.length
    assert_empty @provider.submissions
    batch = RecordingStudioAI::Batch.sole
    assert_equal "failed", batch.status
    assert_equal "usage", batch.error_category
    assert_equal "usage_declined", batch.error_code
    assert_equal stored, batch.error_message
    assert_nil batch.submitted_at
    assert batch.completed_at
    assert_equal 1, batch.failed_item_count
    item = batch.batch_items.sole
    assert_equal "failed", item.status
    assert_equal "usage", item.error_category
    assert_equal "usage_declined", item.error_code
    assert_equal stored, item.error_message
    run = RecordingStudioAI::Run.sole
    assert_equal "failed", run.status
    assert_equal "usage", run.error_category
    assert_equal "usage_declined", run.error_code
    assert_equal stored, run.error_message
    assert run.completed_at
  end

  def test_refresh_ignores_unknown_batch_item_ids_and_fails_the_persisted_item
    submitted = submit_item("known")
    assert_equal "submitted", submitted.status
    failure = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "provider_error", code: "batch_failed", message: "Provider batch failed.",
      retryable: false, provider: "test"
    )
    @provider.refresh_result = RecordingStudioAI::Providers::BatchResult.new(
      status: "failed", provider_batch_id: "provider-batch-1", error: failure,
      items: [
        RecordingStudioAI::Providers::BatchItemResult.new(
          reference: "missing-ref", status: "completed", text: "should-not-persist"
        )
      ]
    )

    response = RecordingStudioAI.refresh_batch(
      batch_id: submitted.batch.id, root_recording: @root, initiator: @initiator
    )

    assert_equal "failed", response.status
    assert_equal "provider_error", response.error.category
    assert_equal "batch_failed", response.error.code
    assert_equal "Provider batch failed.", response.error.message
    assert_equal ["known"], response.items.map(&:reference)
    assert_equal "failed", response.items.first.status
    assert_nil response.items.first.text
    assert_equal "batch_failed", response.items.first.error.code
    assert_equal ["known"], RecordingStudioAI::BatchItem.order(:id).pluck(:reference)
    assert_equal "failed", RecordingStudioAI::Batch.sole.status
    assert_equal "failed", RecordingStudioAI::Run.sole.status
    assert_equal "batch_failed", RecordingStudioAI::Run.sole.error_code
    refute_includes response.items.map(&:text), "should-not-persist"
  end

  def test_submit_rejects_a_non_batch_result_and_fails_persisted_records
    @provider.submit_result = "not-a-batch-result"

    response = submit_item("only")

    refute response.success?
    assert_equal "batch_submission", response.error.category
    assert_equal "batch_submission_failed", response.error.code
    assert_equal "Provider batch submission failed.", response.error.message
    refute_includes response.error.message, "BatchResult"
    refute_includes response.error.message, "TypeError"
    assert_equal 1, @provider.submissions.length
    assert_equal "failed", response.status
    assert_equal "failed", response.batch.status
    assert_equal "batch_submission_failed", response.batch.error_code
    assert_equal ["only"], response.items.map(&:reference)
    assert_equal "failed", response.items.first.status
    assert_equal "batch_submission_failed", response.items.first.error.code
    assert_equal "Provider batch submission failed.", response.items.first.error.message
    assert_equal "failed", RecordingStudioAI::Run.sole.status
    assert_equal "batch_submission", RecordingStudioAI::Run.sole.error_category
  end

  private

  def submit_item(reference)
    RecordingStudioAI.submit_batch(
      items: [{ reference: reference, prompt: "private prompt" }],
      provider: :test, root_recording: @root, initiator: @initiator
    )
  end

  def configured_configuration
    RecordingStudioAI::Configuration.new.tap do |configuration|
      configuration.attribution_validator = ->(**) {}
      configuration.authorization_handler = ->(**) { true }
      configuration.providers[:test] = @provider
      configuration.allowed_provider_overrides = [:test]
      configuration.profiles[:medium] = [{
        provider: :test, model: "batch-model",
        capabilities: %i[generation provider_batch provider_batch_cancellation]
      }]
    end
  end
end
