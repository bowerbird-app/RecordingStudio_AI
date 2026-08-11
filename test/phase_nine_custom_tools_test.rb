# frozen_string_literal: true

require "test_helper"
require "active_record"

migration_file = Dir[File.expand_path("../db/migrate/*_create_recording_studio_ai_persistence_tables.rb", __dir__)].first
require migration_file

require_relative "../app/models/recording_studio_ai/application_record"
require_relative "../app/models/concerns/recording_studio_ai/terminal_immutability"
require_relative "../app/models/recording_studio_ai/run"
require_relative "../app/models/recording_studio_ai/attempt"
require_relative "../app/models/recording_studio_ai/custom_tool_invocation"

class PhaseNineCustomToolsTest < Minitest::Test
  Actor = Struct.new(:id)
  OpenAIClient = Struct.new(:responses)
  GeminiClient = Struct.new(:models)

  class ProviderQueue
    attr_reader :requests

    def initialize(*responses)
      @responses = responses
      @requests = []
    end

    def create(**request)
      requests << request
      @responses.shift || raise("unexpected OpenAI call")
    end

    def generate_content(**request)
      requests << request
      @responses.shift || raise("unexpected Gemini call")
    end
  end

  class ToolAdapter < RecordingStudioAI::Adapters::Base
    attr_reader :requests

    def initialize(*results)
      @results = results
      @requests = []
    end

    def generate(request:, candidate:)
      requests << { request: request, candidate: candidate }
      @results.shift || raise("unexpected provider call")
    end
  end

  def setup
    ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
    bootstrap_external_recording_studio_table
    ActiveRecord::Migration.suppress_messages do
      CreateRecordingStudioAIPersistenceTables.migrate(:up)
    end

    @root_recording = Actor.new(create_recording_id)
    @initiator = Actor.new(51)
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

  def test_definition_validates_parameters_and_applies_defaults
    definition = register_tool

    assert_equal({ "format" => "short", "topic" => "Rails" }, definition.validate_arguments!(topic: "Rails"))

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      definition.validate_arguments!(topic: "Rails", unknown: true)
    end
    assert_equal "custom_tool_validation", error.code

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      definition.validate_arguments!(topic: "Rails", format: "verbose")
    end
    assert_equal "custom_tool_validation", error.code
  end

  def test_custom_tool_executor_receives_restricted_context_with_cancellation_state
    received_context = nil
    adapter = ToolAdapter.new(
      tool_result("call-context", "summarize_record", { "topic" => "Rails" }),
      success_result("continued")
    )
    configure_adapter(adapter)
    register_tool(executor: lambda { |_arguments, context|
      received_context = context
      { value: "ok" }
    })

    response = generate

    assert response.success?
    assert_same @root_recording, received_context.root_recording
    assert_same @initiator, received_context.initiator
    assert_instance_of RecordingStudioAI::Orchestrator::CancellationState, received_context.cancellation_state
    refute received_context.cancellation_state.cancelled?
    refute_respond_to received_context, :provider_client
  end

  def test_definition_supports_all_parameter_types_and_exposes_json_schema
    definition = register_tool(parameters: [
      { name: :label, type: :string, required: true, description: "Label." },
      { name: :count, type: :integer, required: true, description: "Count." },
      { name: :ratio, type: :number, required: true, description: "Ratio." },
      { name: :enabled, type: :boolean, required: true, description: "Enabled." },
      { name: :options, type: :object, required: true, description: "Options." },
      { name: :items, type: :array, required: false, description: "Items.", default: [] }
    ])

    arguments = definition.validate_arguments!(
      label: "Rails", count: 2, ratio: 1.5, enabled: false, options: { compact: true }
    )

    assert_equal [], arguments.fetch("items")
    assert_equal "object", definition.json_schema.fetch("type")
    assert_equal false, definition.json_schema.fetch("additionalProperties")
    assert_equal %w[label count ratio enabled options], definition.json_schema.fetch("required")
    assert_equal "integer", definition.json_schema.dig("properties", "count", "type")
  end

  def test_unknown_tool_reference_is_rejected_before_provider_contact
    adapter = ToolAdapter.new(success_result("must not run"))
    configure_adapter(adapter)

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      generate(custom_tools: [{ key: :missing_tool, version: 1 }])
    end

    assert_equal "custom_tool_validation", error.code
    assert_empty adapter.requests
    assert_equal 0, RecordingStudioAI::Run.count
  end

  def test_executes_tool_and_continues_provider_generation
    executed_context = nil
    register_tool(executor: lambda do |arguments, context|
      executed_context = context
      { summary: "#{arguments.fetch('topic')} summary" }
    end)
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      success_result("Final answer")
    )
    configure_adapter(adapter)

    response = generate

    assert response.success?
    assert_equal "Final answer", response.text
    assert_equal %w[primary continuation], response.attempts.map(&:kind)
    assert_equal 2, adapter.requests.length
    assert_equal "call-1", adapter.requests.last[:request][:custom_tool_results].first[:provider_tool_call_id]
    assert_equal "summarize_record", adapter.requests.last[:request][:custom_tool_results].first[:tool_key]
    assert_equal @root_recording, executed_context.root_recording
    assert_equal @initiator, executed_context.initiator
    assert_equal 1, response.custom_tool_invocations.length

    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "completed", invocation.status
    assert_equal "summarize_record", invocation.tool_key
    assert_equal RecordingStudioAI::Attempt.first.id, invocation.requested_by_attempt_id
    assert_equal RecordingStudioAI::Attempt.second.id, invocation.continued_by_attempt_id
    assert_equal 64, invocation.arguments_digest.length
    assert_equal 64, invocation.result_digest.length
    refute_includes invocation.attributes.values, "Rails summary"
    assert_equal 1, response.run.custom_tool_invocation_count
  end

  def test_confirmation_rejection_stops_before_executor_and_continuation
    executed = false
    register_tool(
      requires_confirmation: true,
      executor: ->(*) { executed = true }
    )
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { false }
    adapter = ToolAdapter.new(tool_result("call-1", "summarize_record", topic: "Rails"))
    configure_adapter(adapter)

    response = generate

    refute response.success?
    refute executed
    assert_equal 1, adapter.requests.length
    assert_equal "custom_tool_rejected", response.error.category
    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "rejected", invocation.status
    assert_equal "rejected", invocation.confirmation_status
  end

  def test_pending_confirmation_does_not_execute_or_terminalize_invocation
    executed = false
    register_tool(requires_confirmation: true, executor: ->(*) { executed = true })
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { :pending }
    configure_adapter(ToolAdapter.new(tool_result("call-1", "summarize_record", topic: "Rails")))

    response = generate

    refute response.success?
    refute executed
    assert_equal "custom_tool_confirmation_required", response.error.category
    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "awaiting_confirmation", invocation.status
    assert_equal "pending", invocation.confirmation_status
    assert_nil invocation.completed_at
  end

  def test_expired_confirmation_is_recorded_without_execution
    executed = false
    register_tool(requires_confirmation: true, executor: ->(*) { executed = true })
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { :expired }
    configure_adapter(ToolAdapter.new(tool_result("call-1", "summarize_record", topic: "Rails")))

    response = generate

    refute response.success?
    refute executed
    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "rejected", invocation.status
    assert_equal "expired", invocation.confirmation_status
  end

  def test_custom_tool_cancellation_state_prevents_continuation
    register_tool(executor: lambda { |_arguments, context|
      context.cancellation_state.cancel!
      "discarded result"
    })
    adapter = ToolAdapter.new(tool_result("call-1", "summarize_record", topic: "Rails"))
    configure_adapter(adapter)

    response = generate

    refute response.success?
    assert_equal "cancelled", response.error.category
    assert_equal 1, adapter.requests.length
    assert_equal "cancelled", RecordingStudioAI::CustomToolInvocation.first.status
  end

  def test_custom_tool_authorization_denial_stops_before_executor
    executed = false
    register_tool(executor: ->(*) { executed = true })
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, **|
      action != "recording_studio_ai.use_custom_tool"
    end
    adapter = ToolAdapter.new(tool_result("call-1", "summarize_record", topic: "Rails"))
    configure_adapter(adapter)

    response = generate

    refute response.success?
    refute executed
    assert_equal "custom_tool_denied", response.error.category
    assert_equal "denied", RecordingStudioAI::CustomToolInvocation.first.status
    assert_equal 1, adapter.requests.length
  end

  def test_destructive_tool_requires_confirmation_and_records_confirmer
    actions = []
    register_tool(read_only: false, destructive: true, requires_confirmation: false)
    RecordingStudioAI.configuration.authorization_handler = lambda do |action:, **|
      actions << action
      true
    end
    RecordingStudioAI.configuration.custom_tool_confirmation_handler = ->(**) { true }
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      success_result("confirmed")
    )
    configure_adapter(adapter)

    response = generate

    assert response.success?
    assert_includes actions, "recording_studio_ai.use_custom_tool"
    assert_includes actions, "recording_studio_ai.confirm_custom_tool"
    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "confirmed", invocation.confirmation_status
    assert_equal @initiator.class.name, invocation.confirmed_by_type
    assert_equal @initiator.id.to_s, invocation.confirmed_by_id
  end

  def test_custom_tool_round_limit_stops_repeated_requests
    register_tool
    RecordingStudioAI.configuration.maximum_custom_tool_rounds = 1
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      tool_result("call-2", "summarize_record", topic: "Ruby")
    )
    configure_adapter(adapter)

    response = generate

    refute response.success?
    assert_equal "custom_tool_failed", response.error.category
    assert_equal %w[primary continuation], response.attempts.map(&:kind)
    assert_equal 1, RecordingStudioAI::CustomToolInvocation.count
  end

  def test_multiple_tool_rounds_accumulate_request_scoped_history
    register_tool
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      tool_result("call-2", "summarize_record", topic: "Ruby"),
      success_result("done")
    )
    configure_adapter(adapter)

    response = generate

    assert response.success?
    assert_equal %w[primary continuation continuation], response.attempts.map(&:kind)
    assert_equal 2, adapter.requests.last[:request][:custom_tool_history].length
    call_ids = adapter.requests.last[:request][:custom_tool_history].map do |round|
      round.fetch(:calls).first.fetch(:provider_tool_call_id)
    end
    assert_equal %w[call-1 call-2], call_ids
  end

  def test_provider_error_with_tool_calls_does_not_execute_tool
    executed = false
    register_tool(executor: ->(*) { executed = true })
    result = tool_result("call-1", "summarize_record", topic: "Rails").with(
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "provider_error",
        code: "invalid_response",
        message: "Provider failed.",
        retryable: false,
        provider: "test"
      )
    )
    adapter = ToolAdapter.new(result)
    configure_adapter(adapter)

    response = generate

    refute response.success?
    refute executed
    assert_equal 0, RecordingStudioAI::CustomToolInvocation.count
    assert_equal 1, adapter.requests.length
  end

  def test_provider_error_on_final_allowed_round_is_not_masked
    register_tool
    RecordingStudioAI.configuration.maximum_custom_tool_rounds = 1
    provider_error = RecordingStudioAI::Contracts::NormalizedError.new(
      category: "provider_unavailable",
      code: "http_503",
      message: "Provider is unavailable.",
      retryable: true,
      provider: "test"
    )
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      tool_result("call-2", "summarize_record", topic: "Ruby").with(error: provider_error)
    )
    configure_adapter(adapter)

    response = generate

    refute response.success?
    assert_equal "provider_unavailable", response.error.category
    assert_equal "http_503", response.error.code
    assert_equal 1, RecordingStudioAI::CustomToolInvocation.count
  end

  def test_provider_tool_identifiers_are_length_bounded
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Adapters::ToolCall.new(
        provider_tool_call_id: "x" * 256,
        key: "summarize_record",
        arguments: {}
      )
    end

    assert_equal "invalid_request", error.code
  end

  def test_total_execution_deadline_stops_before_provider_contact
    register_tool
    adapter = ToolAdapter.new(success_result("must not run"))
    configure_adapter(adapter)
    RecordingStudioAI.configuration.total_execution_timeout = 0

    response = generate

    refute response.success?
    assert_equal "timeout", response.error.category
    assert_equal "execution_deadline_exceeded", response.error.code
    assert_empty adapter.requests
  end

  def test_all_invocations_become_terminal_when_one_of_multiple_tool_calls_fails
    register_tool
    adapter = ToolAdapter.new(
      RecordingStudioAI::Adapters::Result.new(
        tool_calls: [
          RecordingStudioAI::Adapters::ToolCall.new(
            provider_tool_call_id: "call-1", key: "summarize_record", arguments: { topic: "Rails" }
          ),
          RecordingStudioAI::Adapters::ToolCall.new(
            provider_tool_call_id: "call-2", key: "summarize_record", arguments: { "private-value" => true }
          )
        ]
      )
    )
    configure_adapter(adapter)

    response = generate

    refute response.success?
    assert_equal "custom_tool_validation", response.error.category
    assert_equal %w[completed failed], RecordingStudioAI::CustomToolInvocation.order(:id).pluck(:status)
    assert_nil RecordingStudioAI::CustomToolInvocation.first.continued_by_attempt_id
    refute_includes RecordingStudioAI::CustomToolInvocation.second.attributes.values, "private-value"
  end

  def test_oversized_result_fails_without_persisting_payload
    register_tool(executor: ->(*) { "secret" * 100 })
    RecordingStudioAI.configuration.maximum_custom_tool_result_size = 20
    provider_result = tool_result("call-1", "summarize_record", topic: "Rails").with(
      usage: RecordingStudioAI::Contracts::Usage.new(input_tokens: 7, output_tokens: 2, total_tokens: 9)
    )
    adapter = ToolAdapter.new(provider_result)
    configure_adapter(adapter)

    response = generate

    refute response.success?
    assert_equal "custom_tool_failed", response.error.category
    assert_equal "completed", response.attempts.first.status
    assert_nil response.attempts.first.error
    assert_equal 9, response.usage.total_tokens
    assert_equal 9, response.run.total_tokens
    invocation = RecordingStudioAI::CustomToolInvocation.first
    assert_equal "failed", invocation.status
    refute_includes invocation.attributes.values, "secret" * 100
  end

  def test_non_idempotent_tool_does_not_retry_or_fallback_failed_continuation
    register_tool(idempotent: false)
    retryable_failure = RecordingStudioAI::Adapters::Result.new(
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "timeout",
        code: "provider_timeout",
        message: "Provider timed out.",
        retryable: true,
        provider: "test"
      )
    )
    adapter = ToolAdapter.new(
      tool_result("call-1", "summarize_record", topic: "Rails"),
      retryable_failure,
      success_result("must not retry")
    )
    configure_adapter(adapter)
    RecordingStudioAI.configuration.maximum_retries_per_candidate = 2

    response = generate

    refute response.success?
    assert_equal %w[primary continuation], response.attempts.map(&:kind)
    assert_equal 2, adapter.requests.length
    assert_equal "completed", RecordingStudioAI::CustomToolInvocation.first.status
  end

  def test_openai_translates_tool_definition_call_and_continuation
    register_tool
    responses = ProviderQueue.new(
      {
        id: "resp_tool",
        status: "completed",
        output: [{ type: "function_call", call_id: "call-1", name: "summarize_record", arguments: '{"topic":"Rails"}' }]
      },
      { id: "resp_final", status: "completed", output_text: "OpenAI final", output: [] }
    )
    configure_provider(:openai, OpenAIClient.new(responses))

    response = generate(provider: :openai)

    assert response.success?
    assert_equal "OpenAI final", response.text
    function = responses.requests.first[:tools].find { |tool| tool[:type] == "function" }
    assert_equal "summarize_record", function[:name]
    assert_equal false, function.dig(:parameters, "additionalProperties")
    continuation = responses.requests.second
    refute continuation.key?(:previous_response_id)
    assert_equal "Summarize this", continuation[:input].first[:content]
    assert_equal %w[function_call function_call_output], continuation[:input].drop(1).map { |item| item[:type] }
    assert_equal %w[call-1 call-1], continuation[:input].drop(1).map { |item| item[:call_id] }
  end

  def test_gemini_translates_tool_definition_call_and_continuation
    register_tool
    models = ProviderQueue.new(
      {
        "responseId" => "gem_tool",
        "candidates" => [{
          "content" => { "parts" => [{ "functionCall" => { "name" => "summarize_record", "args" => { "topic" => "Rails" } } }] },
          "finishReason" => "STOP"
        }]
      },
      {
        "responseId" => "gem_final",
        "candidates" => [{ "content" => { "parts" => [{ "text" => "Gemini final" }] }, "finishReason" => "STOP" }]
      }
    )
    configure_provider(:gemini, GeminiClient.new(models))

    response = generate(provider: :gemini)

    assert response.success?
    assert_equal "Gemini final", response.text
    declaration = models.requests.first.dig(:config, :tools).first[:function_declarations].first
    assert_equal "summarize_record", declaration[:name]
    continuation_contents = models.requests.second[:contents]
    assert_equal "summarize_record", continuation_contents[-2].dig(:parts, 0, :function_call, :name)
    assert_equal "summarize_record", continuation_contents[-1].dig(:parts, 0, :function_response, :name)
  end

  def test_internal_gemini_transport_camelizes_tool_fields_without_changing_payload_keys
    client = RecordingStudioAI::ProviderClients::Gemini.new(api_key: "secret-key", timeout: 5)
    captured_request = nil
    http = Object.new
    http.define_singleton_method(:request) do |request|
      captured_request = request
      response = Net::HTTPOK.new("1.1", "200", "OK")
      response.instance_variable_set(:@read, true)
      response.instance_variable_set(:@body, '{"responseId":"gem-tool-rest"}')
      response
    end

    Net::HTTP.stub(:start, ->(*, **, &block) { block.call(http) }) do
      client.generate_content(
        model: "gemini-test",
        contents: [
          { role: "model", parts: [{ function_call: { name: "summarize_record", args: { "topic_key" => "Rails" } } }] },
          {
            role: "user",
            parts: [{ function_response: { name: "summarize_record", response: { "result_key" => "done" } } }]
          }
        ],
        config: {
          tools: [{ function_declarations: [{
            name: "summarize_record",
            description: "Summarize.",
            parameters: { "type" => "object", "properties" => { "topic_key" => { "type" => "string" } } }
          }] }]
        }
      )
    end

    body = JSON.parse(captured_request.body)
    assert_equal "summarize_record", body.dig("tools", 0, "functionDeclarations", 0, "name")
    assert_equal "string", body.dig("tools", 0, "functionDeclarations", 0, "parameters", "properties", "topic_key", "type")
    assert_equal "Rails", body.dig("contents", 0, "parts", 0, "functionCall", "args", "topic_key")
    assert_equal "done", body.dig("contents", 1, "parts", 0, "functionResponse", "response", "result_key")
  end

  def test_duplicate_tool_version_registration_is_rejected
    register_tool

    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) { register_tool }

    assert_equal "invalid_request", error.code
    assert_equal 1, RecordingStudioAI.tools.all.length
  end

  private

  def register_tool(executor: ->(arguments, _context) { { topic: arguments.fetch("topic") } },
                    requires_confirmation: false, idempotent: true, parameters: nil,
                    read_only: true, destructive: false)
    RecordingStudioAI.tools.register(
      key: :summarize_record,
      version: 1,
      name: "Summarize record",
      description: "Summarizes a record.",
      use_when: "A concise summary is needed.",
      do_not_use_when: "The source is unavailable.",
      parameters: parameters || [
        { name: :topic, type: :string, required: true, description: "Topic to summarize." },
        {
          name: :format,
          type: :string,
          required: false,
          description: "Summary format.",
          allowed_values: %w[short bullets],
          default: "short"
        }
      ],
      returns: "A serializable summary.",
      cost: :low,
      latency: :fast,
      read_only: read_only,
      destructive: destructive,
      requires_confirmation: requires_confirmation,
      idempotent: idempotent,
      executor_label: "Summarizers.record",
      executor: executor
    )
  end

  def tool_result(call_id, key, arguments)
    RecordingStudioAI::Adapters::Result.new(
      tool_calls: [
        RecordingStudioAI::Adapters::ToolCall.new(
          provider_tool_call_id: call_id,
          key: key,
          arguments: arguments
        )
      ],
      finish_reason: "tool_calls"
    )
  end

  def success_result(text)
    RecordingStudioAI::Adapters::Result.new(text: text, finish_reason: "stop")
  end

  def configure_adapter(adapter)
    configuration = RecordingStudioAI.configuration
    configuration.adapters = { test: adapter }
    configuration.profiles[:medium] = [
      { provider: :test, model: "tool-model", capabilities: %i[generation custom_tools] }
    ]
  end

  def configure_provider(provider, client)
    configuration = RecordingStudioAI.configuration
    configuration.public_send("#{provider}_client=", client)
    configuration.allowed_provider_overrides = [provider]
    configuration.profiles[:medium] = [
      { provider: provider, model: "tool-model", capabilities: %i[generation custom_tools] }
    ]
  end

  def generate(custom_tools: [{ key: :summarize_record, version: 1 }], provider: nil)
    RecordingStudioAI.generate(
      prompt: "Summarize this",
      custom_tools: custom_tools,
      provider: provider,
      root_recording: @root_recording,
      initiator: @initiator
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
