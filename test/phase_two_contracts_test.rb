# frozen_string_literal: true

require "test_helper"

class PhaseTwoContractsTest < Minitest::Test
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

  def test_generate_requires_exactly_one_of_prompt_or_messages
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(root_recording: @root_recording, initiator: @initiator)
    end
    assert_equal "invalid_request", error.code

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Summarize this",
        messages: [{ role: "user", content: "Summarize this" }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end
  end

  def test_generate_validates_message_roles
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        messages: [{ role: "tool", content: "invalid role" }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_match(/messages\[0\]\.role/, error.message)
  end

  def test_purpose_is_length_bounded_machine_data
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::RequestValidation.validate_generation_request!(
        root_recording: @root_recording,
        initiator: @initiator,
        prompt: "hello",
        purpose: "a" * 65
      )
    end

    assert_includes error.message, "at most 64 characters"
  end

  def test_generate_returns_normalized_failed_response_before_provider_integration
    response = RecordingStudioAI.generate(
      prompt: "Summarize this page",
      purpose: "summarize_page",
      root_recording: @root_recording,
      initiator: @initiator,
      metadata: { source: :test, nested: { request_id: 123 } }
    )

    assert_instance_of RecordingStudioAI::Contracts::GenerationResponse, response
    assert_equal false, response.success?
    assert_equal "generation", response.operation
    assert_equal :medium, response.profile
    assert_equal "configuration", response.error.category
    assert_equal "not_implemented", response.error.code
    assert_equal({ "source" => "test", "nested" => { "request_id" => 123 } }, response.metadata)
  end

  def test_generate_bang_raises_execution_error_when_execution_fails
    error = assert_raises(RecordingStudioAI::Errors::ExecutionError) do
      RecordingStudioAI.generate!(
        prompt: "Summarize this page",
        purpose: "summarize_page",
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_instance_of RecordingStudioAI::Contracts::GenerationResponse, error.response
    assert_equal "not_implemented", error.response.error.code
  end

  def test_stream_emits_normalized_resolution_error_and_returns_contract_response
    events = []

    response = RecordingStudioAI.stream(
      prompt: "Stream this",
      purpose: "stream_summary",
      root_recording: @root_recording,
      initiator: @initiator
    ) { |event| events << event }

    assert_instance_of RecordingStudioAI::Contracts::GenerationResponse, response
    assert_equal "stream", response.operation
    assert_equal 1, events.length
    assert_instance_of RecordingStudioAI::Contracts::StreamingEvent, events.first
    assert_equal "error", events.first.type
    assert_equal "not_implemented", events.first.error.code
  end

  def test_stream_bang_requires_block
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.stream!(
        prompt: "Stream this",
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_match(/requires a block/, error.message)
  end

  def test_batch_contracts_validate_and_return_normalized_resolution_failure
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    submit_response = RecordingStudioAI.submit_batch(
      items: [{ reference: "item-1", prompt: "Summarize this" }],
      root_recording: @root_recording,
      initiator: @initiator
    )

    assert_instance_of RecordingStudioAI::Contracts::BatchResponse, submit_response
    assert_equal "batch_submit", submit_response.operation
    assert_equal false, submit_response.success?
    assert_equal "not_implemented", submit_response.error.code
    assert_empty submit_response.items
  end

  def test_batch_submit_rejects_custom_tools
    error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.submit_batch(
        items: [{ reference: "item-1", prompt: "Summarize this", custom_tools: [{ key: :lookup }] }],
        root_recording: @root_recording,
        initiator: @initiator
      )
    end

    assert_equal "invalid_request", error.code
    assert_match(/custom tools/i, error.message)
  end

  def test_tools_registry_supports_register_fetch_and_all_contract
    tool_key = "phase_two_tool_#{Process.pid}_#{rand(1_000_000)}"

    definition = RecordingStudioAI.tools.register(
      key: tool_key,
      version: 1,
      name: "Phase Two Tool",
      description: "A contract-only tool definition.",
      use_when: "Need deterministic test behavior.",
      do_not_use_when: "No deterministic behavior is needed.",
      parameters: [{ name: "query", type: "string", required: true, description: "Query to execute." }],
      returns: "A deterministic response",
      cost: "low",
      latency: "fast",
      read_only: true,
      destructive: false,
      requires_confirmation: false,
      idempotent: true,
      executor_label: "test_executor",
      executor: ->(args, _context) { args.fetch("query") },
      examples: [{ request: "find something", arguments: { query: "abc" } }]
    )

    assert_same definition, RecordingStudioAI.tools.fetch(tool_key)
    assert_same definition, RecordingStudioAI.tools.fetch(tool_key, version: 1)
    assert_includes RecordingStudioAI.tools.all, definition
  end

  def test_contract_containment_rejects_non_serializable_metadata
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Invalid metadata",
        root_recording: @root_recording,
        initiator: @initiator,
        metadata: { sdk_payload: Object.new }
      )
    end
  end

  def test_generation_and_batch_lookup_reject_unknown_keywords
    generation_error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.generate(
        prompt: "Reject typo",
        root_recording: @root_recording,
        initiator: @initiator,
        profle: :low
      )
    end
    lookup_error = assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI.refresh_batch(
        batch_id: "batch-1",
        root_recording: @root_recording,
        initiator: @initiator,
        root_recordng: @root_recording
      )
    end

    assert_match(/unknown keys: profle/, generation_error.message)
    assert_match(/unknown keys: root_recordng/, lookup_error.message)
  end

  def test_public_result_contracts_reject_sdk_objects_in_content_fields
    response_attributes = {
      operation: "generation",
      profile: :medium,
      text: Object.new
    }
    item_attributes = {
      reference: "item-1",
      status: "completed",
      text: Object.new
    }

    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::GenerationResponse.new(**response_attributes)
    end
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::BatchItemResult.new(**item_attributes)
    end
  end

  def test_normalized_error_contract_rejects_unknown_categories
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::NormalizedError.new(
        category: "unknown",
        code: "x",
        message: "Invalid"
      )
    end
  end

  def test_usage_cost_and_attempt_summary_contracts_round_trip
    usage = RecordingStudioAI::Contracts::Usage.new(
      input_tokens: 10,
      output_tokens: 7,
      total_tokens: 17,
      cached_input_tokens: 2,
      reasoning_tokens: 1
    )
    cost = RecordingStudioAI::Contracts::Cost.new(
      amount: 123,
      currency: "USD",
      estimated: true,
      source: "estimate"
    )
    attempt = RecordingStudioAI::Contracts::AttemptSummary.new(
      sequence: 1,
      kind: "primary",
      provider: "openai",
      model: "gpt-x",
      status: "failed",
      usage: usage,
      cost: cost,
      latency: 320,
      finish_reason: "error",
      error: RecordingStudioAI::Contracts::NormalizedError.new(
        category: "provider_error",
        code: "provider_down",
        message: "Provider unavailable",
        retryable: true,
        provider: "openai",
        provider_code: "503"
      )
    )

    response = RecordingStudioAI::Contracts::Response.new(
      operation: "generation",
      purpose: "contract_test",
      profile: :medium,
      usage: usage,
      cost: cost,
      attempts: [attempt]
    )

    assert_equal true, response.success?
    assert_equal 17, response.to_h.dig(:usage, :total_tokens)
    assert_equal "estimate", response.to_h.dig(:cost, :source)
    assert_equal "primary", response.to_h.dig(:attempts, 0, :kind)
  end

  def test_cost_rejects_fractional_or_negative_microunits
    [-1, 123.45].each do |amount|
      assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
        RecordingStudioAI::Contracts::Cost.new(amount: amount, currency: "USD", source: "provider")
      end
    end
  end

  def test_metadata_boundaries_redact_secrets_payloads_and_signed_query_values
    metadata = {
      safe_label: "summary",
      prompt: "private prompt",
      nested: {
        api_key: "secret-key",
        arguments: { account_id: 7 },
        url: "https://example.test/file?signature=private&part=1"
      }
    }

    result = RecordingStudioAI::Providers::Result.new(metadata: metadata)
    event = RecordingStudioAI::Contracts::StreamingEvent.new(type: :completed, metadata: metadata)

    [result.metadata, event.metadata].each do |sanitized|
      assert_equal "summary", sanitized.fetch("safe_label")
      assert_equal "[REDACTED]", sanitized.fetch("prompt")
      assert_equal "[REDACTED]", sanitized.dig("nested", "api_key")
      assert_equal "[REDACTED]", sanitized.dig("nested", "arguments")
      assert_equal "https://example.test/file?signature=%5BREDACTED%5D&part=1", sanitized.dig("nested", "url")
    end
  end

  def test_attempt_summary_contract_rejects_invalid_kind
    assert_raises(RecordingStudioAI::Errors::ContractValidationError) do
      RecordingStudioAI::Contracts::AttemptSummary.new(
        sequence: 1,
        kind: "invalid",
        status: "completed"
      )
    end
  end
end
